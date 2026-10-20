//
//  Domain.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The router's extension points: a domain head (the base expert for one domain), the
//        domain detector that picks it, and a cross-cutting override applied after the head.
//        Adding a domain is a head trained on the shared embedding, a detector that knows the
//        domain, and one `Detector.shared.register(head)`; nothing else moves.
//  PIN:  Garde's protocols. The default detector: a caller's hint wins, else the flat-UI gate marks
//        a screenshot, else camera. The gate misses photographic reel screenshots, so a caller with
//        context (a share extension) passes the screenshot hint.
//

public protocol DomainHead: Sendable {
    var domain: DetectionDomain { get }
    func verdict(_ s: DetectionSignals) throws -> InferenceResult
}

public protocol DomainDetector: Sendable {
    func detect(_ s: DetectionSignals, hint: DetectionDomain?) -> DetectionDomain
}

/// A high-precision guard applied after the head. Empty by default: the validated capture-present
/// override lives in the router's stack, scoped to the screenshot domain.
public protocol DomainOverride: Sendable {
    func apply(_ result: InferenceResult, _ s: DetectionSignals) -> InferenceResult
}

public struct DefaultDomainDetector: DomainDetector {
    public init() {}

    public func detect(_ s: DetectionSignals, hint: DetectionDomain?) -> DetectionDomain {
        if let hint { return hint }
        return s.gate.isScreenshot ? .screenshot : .camera
    }
}
