//
//  Signals.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The Shared Signals stage: what every member of the stack reads, computed once per image.
//        The flat-UI screenshot gate (cheap, eager) and, on first use, the capture reading (the
//        nine values and the signature, from one measurement), DINOv2's two CLS readings (the plain
//        one the camera head reads, the force-resized one the linear heads read) and the plain
//        input's 256 patch tokens the semantic tiles read. A new signal is one more cached reading
//        here.
//  PIN:  The normalized embedding is always the 360×640 force-resize, the plain one the 256/224
//        preprocessing, both at the config's DINOv2 variant. Members never compute a signal
//        themselves, so none is measured twice.
//

import CoreGraphics
import Foundation

public final class DetectionSignals: @unchecked Sendable {
    public let cgImage: CGImage
    public let config: InferenceConfig
    public let gate: ScreenshotGate
    public let width: Int
    public let height: Int
    private let lock = NSLock()
    private var cachedCapture: CaptureReading?
    private var cachedDinoNorm: [Float]?
    private var cachedDinoFusion: [Float]?
    private var cachedTokens: (values: [Float], count: Int, width: Int)?

    public init(cgImage: CGImage, config: InferenceConfig) {
        self.cgImage = cgImage
        self.config = config
        self.gate = ScreenshotLens.gate(cgImage)
        self.width = cgImage.width
        self.height = cgImage.height
    }

    private func cached<T>(_ slot: ReferenceWritableKeyPath<DetectionSignals, T?>, _ make: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        if let value = self[keyPath: slot] { return value }
        let value = try make()
        self[keyPath: slot] = value
        return value
    }

    /// The native-resolution capture measurement: the nine values and the signature.
    public func capture() -> CaptureReading { cached(\.cachedCapture) { CaptureLens.reading(cgImage) } }

    /// The plain DINOv2 embedding the camera head reads.
    public func dinoFusion() throws -> [Float] {
        try cached(\.cachedDinoFusion) { try SemanticLens.fusionEmbedding(cgImage, variant: config.dinoVariant) }
    }

    /// The 360×640 force-resized DINOv2 embedding the linear heads read.
    public func dinoNorm() throws -> [Float] {
        try cached(\.cachedDinoNorm) { try SemanticLens.normalizedEmbedding(cgImage, variant: config.dinoVariant) }
    }

    /// The plain input's 256 patch tokens, row-major [count × width].
    public func patchTokens() throws -> (values: [Float], count: Int, width: Int) {
        try cached(\.cachedTokens) { try SemanticLens.patchTokens(cgImage, variant: config.dinoVariant) }
    }
}
