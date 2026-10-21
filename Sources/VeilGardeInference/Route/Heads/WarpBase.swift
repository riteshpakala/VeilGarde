//
//  WarpBase.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The camera base expert without the fusion head: the warp lens's own result, its weighted
//        score labelled at the config's decision rule (0.56 ± 0.04), handed to the specialist stack
//        where the fused score would go. The sensor lane, the patch map and the capture signature
//        are the lens's, byte for byte what the fusion base carries.
//  PIN:  A measurement mode (InferenceConfig.baseExpert = .warp, the 2026-10-20 detector studies):
//        the stack's combiner was fitted on the fusion head's scores and is used as it stands. The
//        flat-UI gate behaves as in the fusion base (Fusion.screenshotGuard), "real" when the
//        bundle has no screenshot head. The scorer is "warp", so the result JSON says which base ran.
//

import Foundation

enum WarpBase {
    static func run(_ s: DetectionSignals) throws -> InferenceResult {
        let warp = try WarpInference.run(cgImage: s.cgImage, config: s.config)
        if let guarded = Fusion.screenshotGuard(warp: warp, cgImage: s.cgImage, config: s.config, shot: s.gate) { return guarded }
        let r = warp
        var out = InferenceResult(
            scorer: "warp", majorityPrediction: r.majorityPrediction, majorityScore: r.majorityScore,
            weightedPrediction: s.gate.isScreenshot ? "real" : r.weightedPrediction, weightedScore: r.weightedScore,
            patches: r.patches, gridRows: r.gridRows, gridCols: r.gridCols, patchSize: r.patchSize, imageWidth: r.imageWidth, imageHeight: r.imageHeight,
            decisionThreshold: r.decisionThreshold, uncertainBand: r.uncertainBand, nativeScore: r.nativeScore, nativeDisagreement: r.nativeDisagreement,
            captureSignature: r.captureSignature, isScreenshot: s.gate.isScreenshot, sharpness: r.sharpness, specialists: r.specialists,
            semanticTiles: r.semanticTiles, majoritySource: r.majoritySource, tileMapSource: r.tileMapSource,
            sensorRawProbability: r.sensorRawProbability, sensorProbability: r.sensorProbability, sensorPrediction: r.sensorPrediction,
            sensorCalibration: r.sensorCalibration, baseWarpModelSHA256: r.baseWarpModelSHA256, sensorWarpModelSHA256: r.sensorWarpModelSHA256,
            routeDiagnostics: r.routeDiagnostics)
        out.warpWeightedScore = r.weightedScore
        return out
    }
}
