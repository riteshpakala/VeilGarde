//
//  ScreenshotSpecialist.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The screenshot domain's specialist: a resolution-normalized DINOv2 content head for
//        social-media screenshots, where the camera-physics fusion false-positives (real reels
//        read "generated"). On its own it applies the capture-present override (a valid sensor
//        signature pins P toward real); in the stack the router applies that override as a prior,
//        so the compounding stays legible.
//  PIN:  Garde's screenshot specialist (v1.10): real false positives 100% → about 8%, → 0% with
//        the capture prior (the research, quoted). The head's own normalize_size drives its embedding here;
//        the head's threshold and the config's band make the label.
//

import CoreGraphics
import Foundation

public enum ScreenshotSpecialist {
    /// Why a screenshot verdict went the way it did, for logs.
    public enum RouteReason: String, Sendable {
        case gate, captureReal, content
    }

    public static func route(_ cg: CGImage) -> RouteReason {
        if ScreenshotLens.gate(cg).isScreenshot { return .gate }
        if CaptureLens.signature(cg).present { return .captureReal }
        return .content
    }

    /// The head's verdict on a precomputed embedding, with the capture-present override.
    static func verdict(embedding emb: [Float], capture cap: CaptureSignature, config: InferenceConfig) -> (p: Float, verdict: String)? {
        guard let head = HeadRegistry.shared.head(.screenshot, in: config.bundle) else { return nil }
        var p = head.pAI(emb)
        if cap.present { p = min(p, CaptureLaw.realCeiling) }
        let t = head.threshold
        return (p, abs(p - t) < config.decision.band ? "inconclusive" : (p > t ? "generated" : "real"))
    }

    /// The head's verdict on an image (its own normalize size), with the capture-present override.
    static func verdict(_ cg: CGImage, config: InferenceConfig) -> (p: Float, verdict: String, capture: CaptureSignature)? {
        guard let head = HeadRegistry.shared.head(.screenshot, in: config.bundle),
              let emb = try? SemanticLens.normalizedEmbedding(cg, variant: config.dinoVariant, normW: head.normW, normH: head.normH) else { return nil }
        let cap = CaptureLens.signature(cg)
        guard let (p, verdict) = verdict(embedding: emb, capture: cap, config: config) else { return nil }
        return (p, verdict, cap)
    }

    /// A screenshot classified on its own: the content head plus the capture override.
    public static func run(cgImage: CGImage, config: InferenceConfig) throws -> InferenceResult {
        guard let sv = verdict(cgImage, config: config) else { throw VeilGardeFailure.missing("the bundle has no screenshot head") }
        let t = HeadRegistry.shared.head(.screenshot, in: config.bundle)?.threshold ?? 0.5
        return InferenceResult(
            scorer: "screenshot", majorityPrediction: sv.verdict, majorityScore: sv.p, weightedPrediction: sv.verdict, weightedScore: sv.p,
            patches: [], gridRows: 0, gridCols: 0, patchSize: 0, imageWidth: cgImage.width, imageHeight: cgImage.height,
            decisionThreshold: t, uncertainBand: config.decision.band, nativeScore: nil, nativeDisagreement: nil,
            captureSignature: sv.capture, isScreenshot: true, sharpness: nil, majoritySource: .screenshotContent, tileMapSource: .none)
    }
}
