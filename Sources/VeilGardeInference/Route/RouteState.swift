//
//  RouteState.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The router's working state as the mechanisms revise it in order: the P(AI) and
//        its label, the specialist rows recorded so far, and the trace flags that observe (never
//        steer) what the semantic and preview probes did.
//

struct RouteState {
    var p: Float
    var verdict: String
    var stack: [SpecialistContribution]
    var semanticMajority: Float? = nil
    var semanticEvaluated = false
    var semanticTriggered = false
    var semanticDecisive = false
    var previewEvaluated = false
    var previewTriggered = false
    var previewDecisive = false

    init(base: InferenceResult) {
        p = base.p
        verdict = base.prediction
        stack = [SpecialistContribution(name: base.scorer, pAI: base.p, verdict: base.prediction, weight: 1.0)]
    }
}
