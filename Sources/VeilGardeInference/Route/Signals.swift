//
//  Signals.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What every part of one detection shares, computed once: the image, the config, the
//        flat-UI screenshot gate (cheap, eager: the domain detector reads it), and, lazily, the
//        native capture signature, the two DINOv2 embeddings (the fusion head's plain one and the
//        normalized one the heads read), and the warp residual's statistics when the head reads them.
//  PIN:  The reference's signals. The normalized embedding is always the 360×640 force-resize, the
//        fusion embedding the plain 256/224 preprocessing, both at the config's DINOv2 variant.
//

import CoreGraphics
import Foundation
import VeilWatermark

public final class DetectionSignals: @unchecked Sendable {
    public let cgImage: CGImage
    public let config: InferenceConfig
    public let gate: ScreenshotGate
    public let width: Int
    public let height: Int
    private var cachedCapture: CaptureSignature?
    private var cachedDinoNorm: [Float]?
    private var cachedDinoFusion: [Float]?
    private var cachedResidual: [Float]?

    public init(cgImage: CGImage, config: InferenceConfig) {
        self.cgImage = cgImage
        self.config = config
        self.gate = ScreenshotLens.gate(cgImage)
        self.width = cgImage.width
        self.height = cgImage.height
    }

    /// The native-resolution capture signature.
    public func capture() -> CaptureSignature {
        if let c = cachedCapture { return c }
        let c = CaptureLens.signature(cgImage)
        cachedCapture = c
        return c
    }

    /// The resolution-normalized DINOv2 embedding the specialist heads read.
    public func dinoNorm() throws -> [Float] {
        if let e = cachedDinoNorm { return e }
        let e = try SemanticLens.normalizedEmbedding(cgImage, variant: config.dinoVariant)
        cachedDinoNorm = e
        return e
    }

    /// The warp residual's 38 statistics at the 512-px cap (VeilWatermark's ResidualStatistics).
    public func residual() throws -> [Float] {
        if let r = cachedResidual { return r }
        let r = try ResidualStatistics.measure(cgImage)
        cachedResidual = r
        return r
    }

    /// The plain DINOv2 embedding the fusion head reads.
    public func dinoFusion() throws -> [Float] {
        if let e = cachedDinoFusion { return e }
        let e = try SemanticLens.fusionEmbedding(cgImage, variant: config.dinoVariant)
        cachedDinoFusion = e
        return e
    }
}
