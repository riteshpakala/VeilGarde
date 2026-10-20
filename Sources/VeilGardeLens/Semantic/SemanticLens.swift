//
//  SemanticLens.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: DINOv2 as the layers above use it: the model loaded once per weight variant, and an image
//        to its fusion embedding, its normalized (head) embedding, or its 256 patch tokens.
//  PIN:  Garde's Dinov2Cache and embedding entry points. The xxsmall variant is quantized (its
//        Linear slots made int8) before its weights load. Weights come from the WeightLocator;
//        a missing file is an error naming where it was looked for, never a crash.
//

import CoreGraphics
import Foundation
import MLX
import MLXNN

public final class SemanticLens: @unchecked Sendable {
    public static let shared = SemanticLens()
    private let lock = NSLock()
    private var models: [DinoVariant: Dinov2ViT] = [:]

    public func vit(_ variant: DinoVariant = .small) throws -> Dinov2ViT {
        lock.lock()
        defer { lock.unlock() }
        if let m = models[variant] { return m }
        let m = Dinov2ViT()
        if variant.isQuantized { quantize(model: m, groupSize: variant.quantGroupSize, bits: variant.quantBits) }
        try m.loadWeights(url: WeightLocator.shared.require(variant.weightFile))
        models[variant] = m
        return m
    }

    /// The fusion head's embedding: CLS after the plain 256/224 preprocessing.
    public static func fusionEmbedding(_ cg: CGImage, variant: DinoVariant = .small) throws -> [Float] {
        try shared.vit(variant)(Dinov2Preprocess.input(cg)).reshaped(-1).asArray(Float.self)
    }

    /// The specialist heads' embedding: CLS after the normW × normH force-resize.
    public static func normalizedEmbedding(_ cg: CGImage, variant: DinoVariant = .small, normW: Int = 360, normH: Int = 640) throws -> [Float] {
        try shared.vit(variant)(Dinov2Preprocess.inputNormalized(cg, normW: normW, normH: normH)).reshaped(-1).asArray(Float.self)
    }

    /// The 256 patch tokens of the plain input, row-major [256 × 384].
    public static func patchTokens(_ cg: CGImage, variant: DinoVariant = .small) throws -> (values: [Float], count: Int, width: Int) {
        let toks = try shared.vit(variant).patchTokens(Dinov2Preprocess.input(cg))
        return (toks.asArray(Float.self), toks.dim(1), toks.dim(2))
    }

    /// The CLS embedding of an already-preprocessed (1, 224, 224, 3) tensor (parity fixtures).
    public static func embedding(pixels: [Float], variant: DinoVariant = .small) throws -> [Float] {
        try shared.vit(variant)(MLXArray(pixels, [1, 224, 224, 3])).reshaped(-1).asArray(Float.self)
    }
}
