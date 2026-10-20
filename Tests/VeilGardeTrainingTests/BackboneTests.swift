//
//  BackboneTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The DINOv2 import from Hugging Face's checkpoint: the bicubic resize equals PyTorch's
//        bit for bit (bicubic_fixture.json); the rename map covers Dinov2ViT's 222 tensors; and,
//        when this Mac has the checkpoint and the shipped files, small is byte-identical to the
//        file Python exported, xsmall's tensors are byte-identical to Garde's, and (on the GPU)
//        xxsmall's quantized tensors are byte-identical to Garde's.
//

import Foundation
import Testing
import VeilGardeCore
import VeilGardeLens
@testable import VeilGardeTraining

enum Backbone {
    /// The checkpoint the T9's hf/ cache holds (downloaded once with Python's hub client).
    static var checkpoint: URL? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let named = env["VEILGARDE_DINOV2_CHECKPOINT"] { candidates.append(URL(fileURLWithPath: named)) }
        if let area = WorkArea.resolve() {
            let snapshots = area.root.appendingPathComponent("hf/hub/models--facebook--dinov2-small/snapshots", isDirectory: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path))?.sorted() ?? [] {
                candidates.append(snapshots.appendingPathComponent("\(name)/model.safetensors"))
            }
            candidates.append(area.root.appendingPathComponent("hf/models/facebook/dinov2-small/model.safetensors"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A shipped weight file, when this Mac has it.
    static func shipped(_ file: WeightFile) -> URL? {
        if let area = WorkArea.resolve() { WeightLocator.shared.register(area.weights) }
        return WeightLocator.shared.url(file)
    }
}

@Suite("Backbone: DINOv2 from Hugging Face's checkpoint")
struct BackboneTests {
    @Test("the bicubic resize is PyTorch's, bit for bit")
    func bicubic() throws {
        let fixture = try Fixture.json("bicubic_fixture.json")
        let cases = fixture["cases"] as! [[String: Any]]
        #expect(cases.count == 3)
        for c in cases {
            let planes = Int(double(c["channels"])), input = Int(double(c["in"])), output = Int(double(c["out"]))
            let y = TorchBicubic.resize(floats(c["x"]), planes: planes, input: input, output: output)
            let expected = floats(c["y"])
            #expect(y.count == expected.count)
            let differing = zip(y, expected).filter { $0.0.bitPattern != $0.1.bitPattern }.count
            #expect(differing == 0, "\(input)→\(output): \(differing) of \(y.count) values differ from torch")
        }
    }

    @Test("the rename map covers Dinov2ViT's tensors once each")
    func renames() {
        let names = Dinov2Import.renames().map(\.mlx) + ["patch_embed.weight", "pos_embed"]
        #expect(names.count == 222)
        #expect(Set(names).count == 222)
        #expect(Set(Dinov2Import.renames().map(\.hf)).count == 220)
        #expect(names.contains("blocks.11.mlp.fc2.weight") && names.contains("cls_token") && names.contains("norm.bias"))
    }

    @Test("the position bake keeps the CLS row and resizes the grid")
    func bake() throws {
        // A 3×3 grid of 2 channels → 2×2, against the resize run directly.
        let dim = 2, side = 3
        var values: [Float] = [9, -9]
        for p in 0..<(side * side) { for c in 0..<dim { values.append(Float(p * 10 + c)) } }
        let baked = try Dinov2Import.bake(values, shape: [1, 1 + side * side, dim], to: 2)
        #expect(baked.shape == [1, 5, 2])
        #expect(Array(baked.values.prefix(2)) == [9, -9])
        var planes = [Float](repeating: 0, count: dim * side * side)
        for p in 0..<(side * side) { for c in 0..<dim { planes[c * side * side + p] = values[(1 + p) * dim + c] } }
        let direct = TorchBicubic.resize(planes, planes: dim, input: side, output: 2)
        for p in 0..<4 { for c in 0..<dim { #expect(baked.values[(1 + p) * dim + c] == direct[c * 4 + p]) } }
        #expect(throws: VeilGardeFailure.self) { try Dinov2Import.bake(values, shape: [1, 9, dim]) }
    }

    @Test("small is byte-identical to the shipped export; xsmall's tensors are Garde's", .enabled(if: Backbone.checkpoint != nil))
    func importMatchesTheShippedFiles() throws {
        let checkpoint = try #require(Backbone.checkpoint)
        let tensors = try Dinov2Import.convert(try SafetensorsFile(url: checkpoint))
        #expect(tensors.count == 222)
        #expect(tensors["pos_embed"]?.shape == [1, 257, 384])
        #expect(tensors["patch_embed.weight"]?.shape == [384, 14, 14, 3])
        if let small = Backbone.shipped(.dinov2Small) {
            let data = try Dinov2Import.encodeSmall(tensors)
            let comparison = try Dinov2Import.compare(try SafetensorsFile(data: data), to: SafetensorsFile(url: small), referenceName: small.path)
            #expect(comparison.problems.isEmpty, "\(comparison.problems)")
            #expect(comparison.identicalBytes == 222, "max |Δ| \(comparison.maxAbsDifference) at \(comparison.worst ?? "?")")
            #expect(comparison.sameFile, "the file is not byte-identical to \(small.path)")
        }
        if let xsmall = Backbone.shipped(.dinov2XSmall) {
            let data = try Dinov2Import.encodeXSmall(tensors)
            let comparison = try Dinov2Import.compare(try SafetensorsFile(data: data), to: SafetensorsFile(url: xsmall), referenceName: xsmall.path)
            #expect(comparison.problems.isEmpty, "\(comparison.problems)")
            #expect(comparison.identicalBytes == 222, "max |Δ| \(comparison.maxAbsDifference) at \(comparison.worst ?? "?")")
        }
    }
}

extension TrainingMLXSuites {
    @Suite("Backbone on the GPU", .serialized)
    struct BackboneOnGPU {
        @Test("xxsmall quantized from xsmall is Garde's, tensor for tensor",
              .enabled(if: Backbone.shipped(.dinov2XSmall) != nil && Backbone.shipped(.dinov2XXSmall) != nil))
        func xxsmall() throws {
            let xsmall = try #require(Backbone.shipped(.dinov2XSmall)), reference = try #require(Backbone.shipped(.dinov2XXSmall))
            let data = try Dinov2Import.encodeXXSmall(fromXSmall: xsmall)
            let comparison = try Dinov2Import.compare(try SafetensorsFile(data: data), to: SafetensorsFile(url: reference), referenceName: reference.path)
            #expect(comparison.tensors == 366)
            #expect(comparison.problems.isEmpty, "\(comparison.problems.prefix(4))")
            #expect(comparison.identicalBytes == 366, "max |Δ| \(comparison.maxAbsDifference) at \(comparison.worst ?? "?")")
        }
    }
}
