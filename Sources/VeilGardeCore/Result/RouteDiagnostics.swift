//
//  RouteDiagnostics.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The router's trace for one image, additive to the stable verdict fields: the route, the
//        campaign switches, the base and sensor probabilities before routing, the weighted state
//        just before the semantic chain could revise it, and which semantic and preview probes
//        were evaluated, armed and decisive.
//  PIN:  Observation only: these flags record branch decisions and never take part in them.
//

public struct RouteDiagnostics: Sendable, Equatable {
    public let route: String
    public let requestedHint: String?
    public let semanticProfile: String
    public let resultSurface: String
    public let warpP: Float?
    public let sensorRawP: Float?
    public let sensorP: Float?
    public let sensorPrediction: String?
    public let preSemanticP: Float?
    public let preSemanticPrediction: String?
    public let semanticMajority: Float?
    public let semanticEvaluated: Bool
    public let semanticTriggered: Bool
    public let semanticDecisive: Bool
    public let previewEvaluated: Bool
    public let previewTriggered: Bool
    public let previewDecisive: Bool

    public init(route: String, requestedHint: String? = nil, semanticProfile: String = SemanticResponsibility.control.rawValue,
                resultSurface: String = ResultSurface.warpSensor.rawValue, warpP: Float? = nil, sensorRawP: Float? = nil,
                sensorP: Float? = nil, sensorPrediction: String? = nil, preSemanticP: Float? = nil, preSemanticPrediction: String? = nil,
                semanticMajority: Float? = nil, semanticEvaluated: Bool = false, semanticTriggered: Bool = false,
                semanticDecisive: Bool = false, previewEvaluated: Bool = false, previewTriggered: Bool = false, previewDecisive: Bool = false) {
        self.route = route
        self.requestedHint = requestedHint
        self.semanticProfile = semanticProfile
        self.resultSurface = resultSurface
        self.warpP = warpP
        self.sensorRawP = sensorRawP
        self.sensorP = sensorP
        self.sensorPrediction = sensorPrediction
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
