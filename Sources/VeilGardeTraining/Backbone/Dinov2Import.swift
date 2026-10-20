//
//  Dinov2Import.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: DINOv2-small from Hugging Face's checkpoint (facebook/dinov2-small, model.safetensors)
//        into the three files Dinov2ViT loads, from nothing but that checkpoint:
//          small    F32, the 222 tensors renamed to Dinov2ViT's keys, the patch convolution moved
//                   from PyTorch's [O, I, kH, kW] to MLX's [O, kH, kW, I], and the 37×37 position
//                   grid resized to 16×16 (TorchBicubic) and baked in beside the CLS position;
//          xsmall   the same tensors cast to F16 (round to nearest even);
//          xxsmall  xsmall with every Linear quantized by MLX to 8 bits in groups of 64 (weight
//                   packed into U32, scales and biases F16): 366 tensors.
//        `compare` checks a converted file against a reference tensor by tensor.
//  PIN:  the reference export (export_dinov2_mlx.py) for the names, the transpose and the bake (which is
//        HF's interpolate_pos_encoding for a 224 input: F.interpolate to 16×16, bicubic,
//        align_corners False, no antialias); Garde's --export-dino-xxsmall for xxsmall (load
//        xsmall, quantize(model:) at group 64 and 8 bits, save the parameters). small is written
//        in Python safetensors' own layout, so it can be byte-identical to the shipped export; MLX wrote
//        Garde's xsmall and xxsmall with their data in hash-map order, so those are compared by
//        tensor, never by file hash. The checkpoint's mask_token is the one tensor inference never
//        reads, and it is the only one dropped; any other unknown name is refused.
//

import Foundation
import MLX
import MLXNN
import VeilGardeCore
import VeilGardeLens

public enum Dinov2Import {
    public static let repository = "facebook/dinov2-small"
    public static let layers = 12
    public static let hidden = 384
    /// The checkpoint's grid (518 / 14) and the deployed one (224 / 14).
    public static let sourceGrid = 37
    public static let grid = 16
    public static let dropped: Set<String> = ["embeddings.mask_token"]

    /// Dinov2ViT's name ← the checkpoint's, for every tensor copied as it is.
    public static func renames(layers: Int = layers) -> [(mlx: String, hf: String)] {
        var out: [(String, String)] = [
            ("cls_token", "embeddings.cls_token"),
            ("patch_embed.bias", "embeddings.patch_embeddings.projection.bias"),
            ("norm.weight", "layernorm.weight"), ("norm.bias", "layernorm.bias"),
        ]
        for i in 0..<layers {
            let p = "encoder.layer.\(i).", q = "blocks.\(i)."
            out += [
                (q + "norm1.weight", p + "norm1.weight"), (q + "norm1.bias", p + "norm1.bias"),
                (q + "attn.q.weight", p + "attention.attention.query.weight"), (q + "attn.q.bias", p + "attention.attention.query.bias"),
                (q + "attn.k.weight", p + "attention.attention.key.weight"), (q + "attn.k.bias", p + "attention.attention.key.bias"),
                (q + "attn.v.weight", p + "attention.attention.value.weight"), (q + "attn.v.bias", p + "attention.attention.value.bias"),
                (q + "attn.proj.weight", p + "attention.output.dense.weight"), (q + "attn.proj.bias", p + "attention.output.dense.bias"),
                (q + "ls1", p + "layer_scale1.lambda1"),
                (q + "norm2.weight", p + "norm2.weight"), (q + "norm2.bias", p + "norm2.bias"),
                (q + "mlp.fc1.weight", p + "mlp.fc1.weight"), (q + "mlp.fc1.bias", p + "mlp.fc1.bias"),
                (q + "mlp.fc2.weight", p + "mlp.fc2.weight"), (q + "mlp.fc2.bias", p + "mlp.fc2.bias"),
                (q + "ls2", p + "layer_scale2.lambda1"),
            ]
        }
        return out
    }

    /// One converted tensor, F32.
    public struct Tensor: Sendable, Equatable {
        public var shape: [Int]
        public var values: [Float]
    }

    // MARK: small (F32)

    /// The checkpoint's tensors under Dinov2ViT's names, the position grid baked to 16×16.
    public static func convert(_ checkpoint: SafetensorsFile) throws -> [String: Tensor] {
        var out: [String: Tensor] = [:]
        var used = dropped
        func take(_ name: String) throws -> (shape: [Int], values: [Float]) {
            let t = try checkpoint.tensor(name)
            guard t.dtype == "F32" else { throw VeilGardeFailure.data("\(name) is \(t.dtype); the DINOv2 checkpoint is expected in F32") }
            used.insert(name)
            return (t.shape, try checkpoint.float32(name))
        }
        for (mlx, hf) in renames() {
            let t = try take(hf)
            out[mlx] = Tensor(shape: t.shape, values: t.values)
        }
        // The patch convolution: [O, I, kH, kW] → [O, kH, kW, I].
        let conv = try take("embeddings.patch_embeddings.projection.weight")
        guard conv.shape.count == 4 else { throw VeilGardeFailure.data("the patch convolution has shape \(conv.shape)") }
        let (o, i, kh, kw) = (conv.shape[0], conv.shape[1], conv.shape[2], conv.shape[3])
        var moved = [Float](repeating: 0, count: conv.values.count)
        for a in 0..<o { for c in 0..<i { for y in 0..<kh { for x in 0..<kw {
            moved[((a * kh + y) * kw + x) * i + c] = conv.values[((a * i + c) * kh + y) * kw + x]
        } } } }
        out["patch_embed.weight"] = Tensor(shape: [o, kh, kw, i], values: moved)
        // The position embedding: CLS position kept, the patch grid resized and baked.
        let pos = try take("embeddings.position_embeddings")
        out["pos_embed"] = try bake(pos.values, shape: pos.shape)
        let unknown = Set(checkpoint.names).subtracting(used)
        guard unknown.isEmpty else { throw VeilGardeFailure.data("the checkpoint holds tensors this import does not know: \(unknown.sorted().joined(separator: ", "))") }
        return out
    }

    /// [1, 1 + 37·37, 384] → [1, 1 + 16·16, 384], as interpolate_pos_encoding computes it for 224.
    public static func bake(_ values: [Float], shape: [Int], to target: Int = grid) throws -> Tensor {
        guard shape.count == 3, shape[0] == 1 else { throw VeilGardeFailure.data("the position embedding has shape \(shape)") }
        let positions = shape[1] - 1, dim = shape[2]
        let side = Int(Double(positions).squareRoot())
        guard side * side == positions else { throw VeilGardeFailure.data("\(positions) patch positions are not a square grid") }
        // [side·side, dim] → dim planes of side × side, resized, back to [target·target, dim].
        var planes = [Float](repeating: 0, count: dim * positions)
        for p in 0..<positions { for c in 0..<dim { planes[c * positions + p] = values[(1 + p) * dim + c] } }
        let resized = TorchBicubic.resize(planes, planes: dim, input: side, output: target)
        let n = target * target
        var out = [Float](repeating: 0, count: (1 + n) * dim)
        for c in 0..<dim { out[c] = values[c] }
        for p in 0..<n { for c in 0..<dim { out[(1 + p) * dim + c] = resized[c * n + p] } }
        return Tensor(shape: [1, 1 + n, dim], values: out)
    }

    /// The F32 file, in Python safetensors' layout (no metadata, as the shipped export wrote it).
    public static func encodeSmall(_ tensors: [String: Tensor]) throws -> Data {
        try SafetensorsWriter.encode(tensors.map { SafetensorsWriter.Entry($0.key, shape: $0.value.shape, .float32($0.value.values)) }, layout: .python)
    }

    // MARK: xsmall (F16)

    public static func encodeXSmall(_ tensors: [String: Tensor]) throws -> Data {
        try SafetensorsWriter.encode(tensors.map { name, t in
            SafetensorsWriter.Entry(name, shape: t.shape, .float16Bits(t.values.map { Float16($0).bitPattern }))
        }, layout: .python)
    }

    // MARK: xxsmall (8-bit Linear)

    /// xsmall's tensors in a Dinov2ViT, every Linear quantized as the runtime quantizes before it
    /// loads xxsmall, and the resulting parameters written out (Garde's export, unchanged).
    public static func encodeXXSmall(fromXSmall url: URL) throws -> Data {
        let model = Dinov2ViT()
        try model.loadWeights(url: url)
        quantize(model: model, groupSize: DinoVariant.xxsmall.quantGroupSize, bits: DinoVariant.xxsmall.quantBits)
        eval(model)
        var entries: [SafetensorsWriter.Entry] = []
        for (name, array) in model.parameters().flattened() {
            let shape = array.shape
            switch array.dtype {
            case .float16: entries.append(.init(name, shape: shape, .float16Bits(array.asArray(Float16.self).map(\.bitPattern))))
            case .float32: entries.append(.init(name, shape: shape, .float32(array.asArray(Float.self))))
            case .uint32: entries.append(.init(name, shape: shape, .uint32(array.asArray(UInt32.self))))
            default: throw VeilGardeFailure.internalError("xxsmall: \(name) came out \(array.dtype)")
            }
        }
        return try SafetensorsWriter.encode(entries, layout: .python)
    }

    // MARK: Comparison

    public struct Comparison: Codable, Sendable, Equatable {
        public var reference: String
        public var tensors: Int
        public var identicalBytes: Int
        /// The largest |a − b| over every float tensor (packed U32 weights compare by bytes).
        public var maxAbsDifference: Double
        public var worst: String?
        public var problems: [String]
        public var sameFile: Bool

        /// Every tensor present in both with the same dtype and shape, floats within `tolerance`,
        /// packed integers byte-identical.
        public func holds(tolerance: Double) -> Bool { problems.isEmpty && maxAbsDifference <= tolerance }
    }

    public static func compare(_ candidate: SafetensorsFile, to reference: SafetensorsFile, referenceName: String) throws -> Comparison {
        var problems: [String] = []
        let a = Set(candidate.names), b = Set(reference.names)
        for name in a.subtracting(b).sorted() { problems.append("\(name) is not in the reference") }
        for name in b.subtracting(a).sorted() { problems.append("\(name) is missing") }
        var worst = 0.0, worstName: String? = nil, identical = 0
        for name in a.intersection(b).sorted() {
            let x = try candidate.tensor(name), y = try reference.tensor(name)
            guard x.dtype == y.dtype, x.shape == y.shape else {
                problems.append("\(name): \(x.dtype) \(x.shape) against the reference's \(y.dtype) \(y.shape)")
                continue
            }
            if try candidate.bytes(name) == reference.bytes(name) { identical += 1; continue }
            switch x.dtype {
            case "F32", "F16", "BF16", "F64":
                let u = try candidate.float32(name), v = try reference.float32(name)
                for k in 0..<u.count {
                    let d = abs(Double(u[k]) - Double(v[k]))
                    if d > worst || d.isNaN { worst = d.isNaN ? .infinity : d; worstName = name }
                }
            default:
                problems.append("\(name): the \(x.dtype) bytes differ")
            }
        }
        return Comparison(reference: referenceName, tensors: a.intersection(b).count, identicalBytes: identical, maxAbsDifference: worst,
                          worst: worstName, problems: problems, sameFile: candidate.data == reference.data)
    }
}

// MARK: The import, end to end

extension Dinov2Import {
    public struct ImportedFile: Codable, Sendable, Equatable {
        public var variant: String
        public var path: String
        public var sha256: String
        public var bytes: Int
        public var tensors: Int
        /// Against the file already at the destination (or the one the weight search finds).
        public var comparison: Comparison?
        /// A file already sat at the destination, so this one was written beside it.
        public var keptExisting: Bool
    }

    public struct ImportReport: Codable, Sendable, Equatable {
        public var checkpoint: String
        public var checkpointSHA256: String
        public var files: [ImportedFile]
    }

    /// xsmall quantized into xxsmall at `output`, compared with `reference` when there is one.
    public static func exportXXSmall(fromXSmall source: URL, to output: URL, reference: URL?) throws -> ImportedFile {
        let data = try encodeXXSmall(fromXSmall: source)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
        let written = try SafetensorsFile(data: data)
        let comparison = try reference.map { try compare(written, to: SafetensorsFile(url: $0), referenceName: $0.path) }
        return ImportedFile(variant: DinoVariant.xxsmall.rawValue, path: output.path, sha256: ContentHash.sha256Hex(data), bytes: data.count,
                            tensors: written.names.count, comparison: comparison, keptExisting: false)
    }

    /// The checkpoint file: a model.safetensors, a folder holding one, or (nil) a download into
    /// `hfBase` from Hugging Face.
    public static func checkpoint(_ from: URL?, hfBase: URL) throws -> URL {
        let url = try from ?? HubDownload.snapshot(repository, matching: ["model.safetensors", "config.json"], into: hfBase)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw VeilGardeFailure.missing("no checkpoint at \(url.path)") }
        let file = isDirectory.boolValue ? url.appendingPathComponent("model.safetensors") : url
        guard FileManager.default.fileExists(atPath: file.path) else { throw VeilGardeFailure.missing("no model.safetensors in \(url.path)") }
        return file
    }

    /// Converts `checkpoint` into each of `variants` under `output`. A file already at the
    /// destination is compared, then kept, and the new one goes to `output`/imported/ unless
    /// `replace`; `reference` names what to compare against when the destination is empty.
    public static func importWeights(checkpoint: URL, variants: [DinoVariant], output: URL, replace: Bool,
                                     reference: (DinoVariant) -> URL?, note: (String) -> Void = { _ in }) throws -> ImportReport {
        let source = try SafetensorsFile(url: checkpoint)
        note("import-dinov2: \(source.names.count) tensors in \(checkpoint.path)")
        let tensors = try convert(source)
        var files: [ImportedFile] = []
        var xsmallURL: URL?
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("veilgarde-dinov2-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let wanted = Set(variants)
        for variant in DinoVariant.allCases where wanted.contains(variant) || (variant == .xsmall && wanted.contains(.xxsmall)) {
            let data: Data
            switch variant {
            case .small: data = try encodeSmall(tensors)
            case .xsmall: data = try encodeXSmall(tensors)
            case .xxsmall:
                guard let xsmallURL else { throw VeilGardeFailure.internalError("xxsmall needs xsmall first") }
                data = try encodeXXSmall(fromXSmall: xsmallURL)
            }
            let name = variant.weightFile.rawValue
            if !wanted.contains(variant) {          // xsmall only as xxsmall's input
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                xsmallURL = scratch.appendingPathComponent(name)
                try data.write(to: xsmallURL!)
                continue
            }
            var destination = output.appendingPathComponent(name)
            let existing = FileManager.default.fileExists(atPath: destination.path)
            let compareTo = existing ? destination : reference(variant)
            let written = try SafetensorsFile(data: data)
            let comparison = try compareTo.map { try compare(written, to: SafetensorsFile(url: $0), referenceName: $0.path) }
            if existing && !replace { destination = output.appendingPathComponent("imported/\(name)") }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            if variant == .xsmall { xsmallURL = destination }
            files.append(ImportedFile(variant: variant.rawValue, path: destination.path, sha256: ContentHash.sha256Hex(data), bytes: data.count,
                                      tensors: written.names.count, comparison: comparison, keptExisting: existing && !replace))
            note("import-dinov2: \(variant.rawValue) → \(destination.path)")
        }
        return ImportReport(checkpoint: checkpoint.path, checkpointSHA256: try ContentHash.sha256Hex(fileAt: checkpoint), files: files)
    }
}
