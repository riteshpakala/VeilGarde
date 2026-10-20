//
//  SemanticChain.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The last compounding step, on the semantic-tile map: the render arbiter (the cgi head,
//        consulted once on a semantic-generated against weighted-real conflict), zoom escalation
//        (off), the preview tail (live), the authority seam that lets only the production profile
//        commit a probe's revision, the x-domain gate (off), render taxonomy (suspended), the
//        semantic-tiles row, and, for the legacy surface only, the semantic majority as the public
//        majority.
//  PIN:  Garde's semantic block, in its order. Every probe revises a SHADOW weighted state (Probe);
//        PublicSurface.project commits it only under `.control`. `.semanticRemoved` never builds
//        the map, so no ViT forward runs.
//

enum SemanticChain {
    /// The shadow weighted state the probes revise.
    struct Probe {
        var p: Float
        var verdict: String
        var decisive = false
        var previewDecisive = false
    }

    struct Outcome {
        var semanticTiles: [[Float]]?
        var majorityPrediction: String
        var majorityScore: Float
        var majoritySource: ResultSource
        var tileMapSource: ResultSource
    }

    static func apply(_ state: inout RouteState, _ s: DetectionSignals, base: InferenceResult, domain: DetectionDomain, capture cap: CaptureSignature) -> Outcome {
        let mechanisms = s.config.mechanisms
        let canDecide = mechanisms.semanticResponsibility == .control
        var probe = Probe(p: state.p, verdict: state.verdict)
        let initial = PublicSurface.initial(base: base, domain: domain, surface: mechanisms.resultSurface)
        var outcome = Outcome(semanticTiles: nil, majorityPrediction: initial.prediction, majorityScore: initial.score,
                              majoritySource: initial.majoritySource, tileMapSource: initial.tileMapSource)

        guard mechanisms.semanticResponsibility != .semanticRemoved, let sm = SemanticTiles.map(s.cgImage, config: s.config) else {
            if mechanisms.resultSurface == .legacySemantic {
                // The pre-Stage-1 fallback without a semantic map: the base majority surfaces only
                // for coherent native capture.
                let coherent = cap.valid && cap.present && base.majorityPrediction == state.verdict
                outcome.majorityPrediction = coherent ? base.majorityPrediction : "inconclusive"
                outcome.majorityScore = base.majorityScore
            }
            return outcome
        }
        state.semanticMajority = sm.majority
        state.semanticEvaluated = true
        outcome.semanticTiles = sm.grid
        let semVerdict = sm.majority > 0.5 ? "generated" : "real"

        // The render arbiter: the cgi head names the rendered-not-generated family, once.
        var renderArbiterP: Float? = nil
        if sm.majority > 0.5, probe.verdict == "real", let h = HeadRegistry.shared.head(.cgi, in: s.config.bundle), let emb = try? s.dinoNorm() {
            renderArbiterP = h.pAI(emb)
        }
        ZoomEscalation.apply(&probe, &state, s, capture: cap, semanticMajority: sm.majority, renderArbiterP: renderArbiterP, canDecide: canDecide)
        PreviewTail.apply(&probe, &state, s, capture: cap, semanticMajority: sm.majority, canDecide: canDecide)

        let projection = PublicSurface.project(profile: mechanisms.semanticResponsibility, originalP: state.p, originalVerdict: state.verdict,
                                               probeP: probe.p, probeVerdict: probe.verdict, probeDecisive: probe.decisive)
        state.p = projection.p
        state.verdict = projection.verdict
        state.semanticDecisive = projection.decisive
        state.previewDecisive = canDecide && probe.previewDecisive

        let domainGated = mechanisms.xDomainGate && !cap.present
            && (HeadRegistry.shared.centroids(in: s.config.bundle)?.isMemeFamily(sm.meanToken) ?? false)
        let renderFires = mechanisms.renderTaxonomy && semVerdict == "generated" && state.verdict == "real" && (renderArbiterP ?? -1) >= 0.5
        if renderFires, let rp = renderArbiterP {
            state.semanticTriggered = true
            state.stack.append(SpecialistContribution(name: "render-arbiter", pAI: rp, verdict: "render", weight: 0.0))
        }
        state.stack.append(SpecialistContribution(name: "semantic-tiles", pAI: sm.majority, verdict: semVerdict,
                                                  weight: canDecide ? (semVerdict == state.verdict ? 1.0 : 0.25) : 0.0))
        if domainGated {
            state.stack.append(SpecialistContribution(name: "domain-gate", pAI: sm.majority, verdict: "muted", weight: 0.0))
        }
        if mechanisms.resultSurface == .legacySemantic {
            outcome.majorityScore = sm.majority
            outcome.majorityPrediction = PublicSurface.legacySemanticPrediction(semanticVerdict: semVerdict, weightedVerdict: state.verdict,
                                                                                renderFires: renderFires, domainGated: domainGated)
            outcome.majoritySource = .semanticTiles
            outcome.tileMapSource = .semanticTiles
        }
        return outcome
    }
}
