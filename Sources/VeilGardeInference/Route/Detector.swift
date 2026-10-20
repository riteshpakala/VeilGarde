//
//  Detector.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The router, the one entry point of the full detector. It picks the image's domain, runs
//        that domain's base expert (camera: the warp lens and the fusion head; screenshot: the
//        content head), then compounds the high-precision priors on it in a fixed order: capture
//        and the pooled specialists, the frame seam, the semantic chain. The result keeps two
//        numbers: `majority`, the camera-sensor anchor, and `weighted`, the compounded score.
//  PIN:  Garde's router, unchanged in order and arithmetic, split one mechanism per file.
//        Stacking, not blending: a monolithic combiner regressed real false positives 8% → 50–92%
//        in the research's measurement, the stack holds them at 0%. Routing is never by image size. The
//        weighted state is frozen before the semantic chain (preSemantic) for replay.
//

import CoreGraphics
import Foundation

public final class Detector: @unchecked Sendable {
    public static let shared = Detector()
    private let lock = NSLock()
    private var heads: [DetectionDomain: DomainHead] = [:]
    private var overrides: [DomainOverride] = []
    private var domainDetector: DomainDetector = DefaultDomainDetector()

    public init() {
        register(CameraFusionHead())
        register(ScreenshotContentHead())
    }

    public func register(_ head: DomainHead) { lock.lock(); heads[head.domain] = head; lock.unlock() }
    public func register(override o: DomainOverride) { lock.lock(); overrides.append(o); lock.unlock() }
    public func setDomainDetector(_ d: DomainDetector) { lock.lock(); domainDetector = d; lock.unlock() }

    private func snapshot() -> (DomainDetector, [DetectionDomain: DomainHead], [DomainOverride]) {
        lock.lock()
        defer { lock.unlock() }
        return (domainDetector, heads, overrides)
    }

    /// The full verdict for one image.
    public func detect(cgImage: CGImage, config: InferenceConfig, hint: DetectionDomain? = nil) throws -> (result: InferenceResult, domain: DetectionDomain) {
        let s = DetectionSignals(cgImage: cgImage, config: config)
        let (picker, registered, _) = snapshot()
        let domain = picker.detect(s, hint: hint)
        let base = try (registered[domain] ?? registered[.camera]!).verdict(s)

        var state = RouteState(base: base)
        let cap = s.capture()
        CapturePriors.apply(&state, s, domain: domain, capture: cap)
        try FrameSeam.apply(&state, s, capture: cap, hint: hint, detector: self)
        let preSemanticP = state.p
        let preSemanticPrediction = state.verdict
        let surfaced = SemanticChain.apply(&state, s, base: base, domain: domain, capture: cap)

        let diagnostics = RouteDiagnostics(
            route: domain.rawValue, requestedHint: hint?.rawValue,
            semanticProfile: config.mechanisms.semanticResponsibility.rawValue, resultSurface: config.mechanisms.resultSurface.rawValue,
            warpP: base.weightedScore, sensorRawP: base.sensorRawProbability, sensorP: base.sensorProbability, sensorPrediction: base.sensorPrediction,
            preSemanticP: preSemanticP, preSemanticPrediction: preSemanticPrediction, semanticMajority: state.semanticMajority,
            semanticEvaluated: state.semanticEvaluated, semanticTriggered: state.semanticTriggered, semanticDecisive: state.semanticDecisive,
            previewEvaluated: state.previewEvaluated, previewTriggered: state.previewTriggered, previewDecisive: state.previewDecisive)
        let result = PublicSurface.routed(
            base: base, weightedPrediction: state.verdict, weightedScore: state.p, capture: cap, specialists: state.stack,
            semanticTiles: surfaced.semanticTiles, majorityPrediction: surfaced.majorityPrediction, majorityScore: surfaced.majorityScore,
            majoritySource: surfaced.majoritySource, tileMapSource: surfaced.tileMapSource, routeDiagnostics: diagnostics)
        return (result, domain)
    }
}
