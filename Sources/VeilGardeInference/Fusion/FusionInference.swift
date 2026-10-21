//
//  FusionInference.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The camera base expert: the warp lens's weighted score, the DINOv2 CLS embedding, the nine
//        capture values and the three sharpness values (397 columns) through the fusion head, one
//        fused P(AI) at 0.5 ± band. The warp grid and the sensor lane ride along unchanged. If the
//        flat-UI gate fires, the screenshot head takes the verdict (or "real" without that head).
//  PIN:  Garde's fuseVerdict and runFusionInferenceFast. Column order [warp, dino(384), cap(9),
//        sharp(3)] is the head's (FusionVector). The head and the band come from the config's
//        bundle and decision rule; the operating point 0.5 is fixed (do not unify with 0.56). The
//        screenshot guard is shared with the warp-only base (WarpBase), and the warp lens's own
//        score rides along beside the fused one (InferenceResult.warpWeightedScore, never encoded).
//

import CoreGraphics
import Foundation

public enum Fusion {
    public static let operatingPoint: Float = 0.5

    /// The 397-value row for an image whose warp result is known.
    static func vector(warp: InferenceResult, cgImage: CGImage, variant: DinoVariant) throws -> [Float] {
        let emb = try SemanticLens.fusionEmbedding(cgImage, variant: variant)
        let cap = CaptureLens.features(cgImage).asVector
        let s = warp.sharpness
        let sharp: [Float] = [s?.salientSharp ?? 0, s?.globalSharp ?? 0, s?.sharpRatio ?? 0]
        return [warp.weightedScore] + emb + cap + sharp
    }

    /// The fused verdict on top of a warp result.
    public static func verdict(warp: InferenceResult, cgImage: CGImage, config: InferenceConfig) throws -> InferenceResult {
        guard let headURL = config.bundle.url(.fusionHead) else { throw VeilGardeFailure.missing("the bundle has no fusion head") }
        let head = try TreeModelCache.shared.model(headURL)
        let p = head.predict(try vector(warp: warp, cgImage: cgImage, variant: config.dinoVariant))
        let t = operatingPoint
        let shot = ScreenshotLens.gate(cgImage)
        if let guarded = screenshotGuard(warp: warp, cgImage: cgImage, config: config, shot: shot) { return guarded }
        let verdict = shot.isScreenshot ? "real" : (abs(p - t) < config.decision.band ? "inconclusive" : (p > t ? "generated" : "real"))
        var fused = InferenceResult(
            scorer: "fusion", majorityPrediction: warp.majorityPrediction, majorityScore: warp.majorityScore, weightedPrediction: verdict, weightedScore: p,
            patches: warp.patches, gridRows: warp.gridRows, gridCols: warp.gridCols, patchSize: warp.patchSize,
            imageWidth: warp.imageWidth, imageHeight: warp.imageHeight, decisionThreshold: t, uncertainBand: config.decision.band,
            nativeScore: warp.nativeScore, nativeDisagreement: warp.nativeDisagreement, captureSignature: warp.captureSignature,
            isScreenshot: shot.isScreenshot, sharpness: warp.sharpness, majoritySource: .warpSensor, tileMapSource: .warpSensor,
            sensorRawProbability: warp.sensorRawProbability, sensorProbability: warp.sensorProbability, sensorPrediction: warp.sensorPrediction,
            sensorCalibration: warp.sensorCalibration, baseWarpModelSHA256: warp.baseWarpModelSHA256,
            sensorWarpModelSHA256: warp.sensorWarpModelSHA256, routeDiagnostics: warp.routeDiagnostics)
        fused.warpWeightedScore = warp.warpWeightedScore ?? warp.weightedScore
        return fused
    }

    /// The flat-UI gate inside the camera base: when it fires and the bundle has a screenshot head,
    /// that head's verdict is the base's. Nil otherwise.
    static func screenshotGuard(warp: InferenceResult, cgImage: CGImage, config: InferenceConfig, shot: ScreenshotGate) -> InferenceResult? {
        guard shot.isScreenshot, let sv = ScreenshotSpecialist.verdict(cgImage, config: config) else { return nil }
        var r = InferenceResult(
            scorer: "screenshot", majorityPrediction: sv.verdict, majorityScore: sv.p, weightedPrediction: sv.verdict, weightedScore: sv.p,
            patches: warp.patches, gridRows: warp.gridRows, gridCols: warp.gridCols, patchSize: warp.patchSize,
            imageWidth: warp.imageWidth, imageHeight: warp.imageHeight,
            decisionThreshold: HeadRegistry.shared.head(.screenshot, in: config.bundle)?.threshold ?? 0.5, uncertainBand: config.decision.band,
            nativeScore: warp.nativeScore, nativeDisagreement: warp.nativeDisagreement, captureSignature: sv.capture, isScreenshot: true,
            sharpness: warp.sharpness, majoritySource: .screenshotContent, tileMapSource: .warpSensor,
            sensorRawProbability: warp.sensorRawProbability, sensorProbability: warp.sensorProbability, sensorPrediction: warp.sensorPrediction,
            sensorCalibration: warp.sensorCalibration, baseWarpModelSHA256: warp.baseWarpModelSHA256,
            sensorWarpModelSHA256: warp.sensorWarpModelSHA256, routeDiagnostics: warp.routeDiagnostics)
        r.warpWeightedScore = warp.warpWeightedScore ?? warp.weightedScore
        return r
    }

    /// The warp lens, then the fusion head.
    public static func run(cgImage: CGImage, config: InferenceConfig, progress: (Int, Int) -> Void = { _, _ in }) throws -> InferenceResult {
        let warp = try WarpInference.run(cgImage: cgImage, config: config, progress: progress)
        return try verdict(warp: warp, cgImage: cgImage, config: config)
    }
}
