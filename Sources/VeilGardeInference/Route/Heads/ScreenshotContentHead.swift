//
//  ScreenshotContentHead.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The screenshot domain's base expert: the RAW resolution-normalized content P(AI), with no
//        warp grid. The capture-present override is a stack prior in the router, so the stack
//        shows the raw read and the override separately.
//  PIN:  Garde's ScreenshotContentHead: the shared 360×640 embedding (signals), the head's own
//        threshold, the config's band.
//

public struct ScreenshotContentHead: DomainHead {
    public let domain: DetectionDomain = .screenshot
    public init() {}

    public func verdict(_ s: DetectionSignals) throws -> InferenceResult {
        guard let head = HeadRegistry.shared.head(.screenshot, in: s.config.bundle) else {
            throw VeilGardeFailure.missing("the bundle has no screenshot head")
        }
        let emb = try s.dinoNorm()
        let cap = s.capture()
        let p = head.pAI(emb)
        let t = head.threshold
        let verdict = abs(p - t) < s.config.decision.band ? "inconclusive" : (p > t ? "generated" : "real")
        return InferenceResult(
            scorer: "screenshot", majorityPrediction: verdict, majorityScore: p, weightedPrediction: verdict, weightedScore: p,
            patches: [], gridRows: 0, gridCols: 0, patchSize: 0, imageWidth: s.width, imageHeight: s.height,
            decisionThreshold: t, uncertainBand: s.config.decision.band, nativeScore: nil, nativeDisagreement: nil,
            captureSignature: cap, isScreenshot: true, sharpness: nil, majoritySource: .screenshotContent, tileMapSource: .none)
    }
}
