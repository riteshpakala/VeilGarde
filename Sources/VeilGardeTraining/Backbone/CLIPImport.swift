//
//  CLIPImport.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: CLIP ViT-B/32's vision tower from a Hugging Face checkpoint in safetensors (a full
//        CLIPModel's model.safetensors, or a vision-only one) into the file CLIPVision loads:
//        "vision_model." dropped from every key, the text tower and position ids left out, the
//        patch convolution moved from PyTorch's [O, I, kH, kW] to MLX's [O, kH, kW, I], F32.
//  PIN:  The same tensors the Python reference exports from the official checkpoint (whose main
//        branch ships only a pickle, which Swift does not read).
//

import Foundation
import MLX
import VeilGardeCore
import VeilGardeLens

public enum CLIPImport {
    public struct Report: Codable, Sendable, Equatable {
        public var tensors: Int
        public var sha256: String
        public var output: String
    }

    public static func convert(from source: URL, to output: URL) throws -> Report {
        let all = try loadArrays(url: source)
        var out: [String: MLXArray] = [:]
        for (key, value) in all {
            let name: String
            if key.hasPrefix("vision_model.") { name = String(key.dropFirst("vision_model.".count)) }
            else if key == "visual_projection.weight" { name = key }
            else if key.hasPrefix("embeddings.") || key.hasPrefix("encoder.") || key.hasPrefix("pre_layrnorm") || key.hasPrefix("post_layernorm") { name = key }
            else { continue }
            if name.hasSuffix("position_ids") { continue }
            var a = value.asType(.float32)
            if name == "embeddings.patch_embedding.weight" && a.dim(1) == 3 { a = a.transposed(0, 2, 3, 1) }
            out[name] = a
        }
        guard out["visual_projection.weight"] != nil, out["embeddings.patch_embedding.weight"] != nil else {
            throw VeilGardeFailure.data("\(source.lastPathComponent) holds no CLIP vision tower (no vision_model.* and visual_projection.weight)")
        }
        // A load check: the converted tensors must fill CLIPVision exactly.
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try save(arrays: out, metadata: ["layout": "veilgarde-clip-vision-v1", "source": source.lastPathComponent], url: output)
        try CLIPVision().loadWeights(url: output)
        return Report(tensors: out.count, sha256: try ContentHash.sha256Hex(fileAt: output), output: output.path)
    }
}
