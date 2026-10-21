//
//  RouteDiagnostics.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The router's trace for one image, beside the verdict: the route, the semantic profile,
//        whether the flat-UI gate fired, the base expert's own P(AI), the state just before the
//        semantic chain could revise it, and which semantic and preview probes were evaluated,
//        armed and decisive.
//  PIN:  Observation only: these flags record branch decisions and never take part in them.
//

public struct RouteDiagnostics: Sendable, Equatable {
    public let route: String
    public let requestedHint: String?
    public let semanticProfile: String
    /// The flat-UI gate fired (the camera base then hands the verdict to the screenshot head).
    public let screenshotGate: Bool
    /// The base expert's own P(AI), before any mechanism.
    public let baseP: Float
    public let preSemanticP: Float
    public let preSemanticPrediction: String
    public let semanticMajority: Float?
    public let semanticEvaluated: Bool
    public let semanticTriggered: Bool
    public let semanticDecisive: Bool
    public let previewEvaluated: Bool
    public let previewTriggered: Bool
    public let previewDecisive: Bool

    public init(route: String, requestedHint: String? = nil, semanticProfile: String = SemanticResponsibility.control.rawValue,
                screenshotGate: Bool = false, baseP: Float, preSemanticP: Float, preSemanticPrediction: String,
                semanticMajority: Float? = nil, semanticEvaluated: Bool = false, semanticTriggered: Bool = false,
                semanticDecisive: Bool = false, previewEvaluated: Bool = false, previewTriggered: Bool = false, previewDecisive: Bool = false) {
        self.route = route
        self.requestedHint = requestedHint
        self.semanticProfile = semanticProfile
        self.screenshotGate = screenshotGate
        self.baseP = baseP
        self.preSemanticP = preSemanticP
        self.preSemanticPrediction = preSemanticPrediction
        self.semanticMajority = semanticMajority
        self.semanticEvaluated = semanticEvaluated
        self.semanticTriggered = semanticTriggered
        self.semanticDecisive = semanticDecisive
        self.previewEvaluated = previewEvaluated
        self.previewTriggered = previewTriggered
        self.previewDecisive = previewDecisive
    }
}
