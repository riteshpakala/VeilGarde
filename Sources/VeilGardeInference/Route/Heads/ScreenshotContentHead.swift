//
//  ScreenshotContentHead.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The screenshot domain's base expert: the RAW resolution-normalized content P(AI). The
//        capture-present override is a stack prior in the router, so the stack shows the raw read
//        and the override separately.
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
        return InferenceResult(scorer: "screenshot", prediction: verdict, p: p, threshold: t, band: s.config.decision.band,
                               imageWidth: s.width, imageHeight: s.height, captureSignature: cap)
    }
}
