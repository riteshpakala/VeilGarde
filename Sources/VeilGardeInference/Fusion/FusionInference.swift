//
//  FusionInference.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The camera base expert: DINOv2 and the nine capture values through the fusion head, one
//        P(AI) at 0.5 ± band. The head's width names its row (FusionLayout): the plain CLS and
//        capture, 393 columns, or both DINOv2 readings and capture, 777. If the flat-UI gate fires,
//        the screenshot head takes the verdict (or "real" without that head). Also the base
//        probability with the capture-validity shortcut neutralized, which the preview tail asks for.
//  PIN:  Column order is the layout's (FusionLayout.columns). The force-resized reading is the one
//        the specialist heads read, cached in the signals, so the wider row costs no DINOv2 pass. The
//        residual layout adds the warp residual's 38 statistics, measured by the watermark's code.
//        The head and the band come from the config's bundle and decision rule. Neutralizing sets valid = 1 and native px =
//        max(·, 576): invalid-capture rows were 85.5% generated in the 2026-07-17 measurement and
//        taught the base "small ⇒ AI". The preview tail's cuts were set against the head before
//        2026-10-21; they are kept, and the tail's firing is reported in route_diagnostics.
//

import CoreGraphics
import Foundation

public enum Fusion {
    /// The row in a layout: the plain DINOv2 embedding, the force-resized one for `.bothReadings`,
    /// and the nine capture values (`capture` stands in for them when given).
    static func vector(_ s: DetectionSignals, layout: FusionLayout, capture: [Float]? = nil) throws -> [Float] {
        let cap = capture ?? CaptureLens.features(s.cgImage).asVector
        switch layout {
        case .dinoCapture: return try s.dinoFusion() + cap
        case .bothReadings: return try s.dinoFusion() + s.dinoNorm() + cap
        case .bothReadingsResidual: return try s.dinoFusion() + s.dinoNorm() + cap + s.residual()
        }
    }

    /// The camera base expert's verdict.
    public static func verdict(_ s: DetectionSignals) throws -> InferenceResult {
        guard let headURL = s.config.bundle.url(.fusionHead) else { throw VeilGardeFailure.missing("the bundle has no fusion head") }
        if let guarded = screenshotGuard(s) { return guarded }
        let head = try TreeModelCache.shared.model(headURL)
        let p = head.predict(try vector(s, layout: FusionLayout.of(width: head.numFeatures)))
        let rule = s.config.decision
        return InferenceResult(scorer: "fusion", prediction: s.gate.isScreenshot ? "real" : rule.label(p), p: p,
                               threshold: rule.threshold, band: rule.band, imageWidth: s.width, imageHeight: s.height,
                               captureSignature: s.capture())
    }

    /// The flat-UI gate inside the camera base: when it fires and the bundle has a screenshot head,
    /// that head's verdict is the base's. Nil otherwise.
    static func screenshotGuard(_ s: DetectionSignals) -> InferenceResult? {
        guard s.gate.isScreenshot, let sv = ScreenshotSpecialist.verdict(s.cgImage, config: s.config) else { return nil }
        let t = HeadRegistry.shared.head(.screenshot, in: s.config.bundle)?.threshold ?? 0.5
        return InferenceResult(scorer: "screenshot", prediction: sv.verdict, p: sv.p, threshold: t, band: s.config.decision.band,
                               imageWidth: s.width, imageHeight: s.height, captureSignature: sv.capture)
    }

    /// The base probability with the capture-validity flags neutralized (the preview tail's arbiter).
    static func neutralizedBaseP(_ s: DetectionSignals) -> Float? {
        guard let url = s.config.bundle.url(.fusionHead), let head = try? TreeModelCache.shared.model(url),
              let layout = try? FusionLayout.of(width: head.numFeatures) else { return nil }
        var cap = CaptureLens.features(s.cgImage).asVector
        if cap.count >= 4 { cap[1] = 1.0; cap[3] = max(cap[3], 576.0) }
        guard let row = try? vector(s, layout: layout, capture: cap) else { return nil }
        return head.predict(row)
    }
}
