//
//  SemanticChain.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The last compounding step, on the semantic-tile map: the preview tail (live), the
//        authority seam that lets only the production profile commit a probe's revision, and the
//        semantic-tiles row.
//  PIN:  The reference's semantic block, in its order. Every probe revises a SHADOW state (Probe);
//        PublicSurface.project commits it only under `.control`. `.semanticRemoved` never builds
//        the map, so no ViT forward runs. Zoom escalation, the x-domain gate and the render
//        taxonomy, none of which ran by default, left on 2026-10-21.
//

enum SemanticChain {
    /// The shadow state the probes revise.
    struct Probe {
        var p: Float
        var verdict: String
        var decisive = false
        var previewDecisive = false
    }

    /// The semantic tiles when the map was built, else nil.
    static func apply(_ state: inout RouteState, _ s: DetectionSignals, capture cap: CaptureSignature) -> [[Float]]? {
        let profile = s.config.semanticResponsibility
        let canDecide = profile == .control
        var probe = Probe(p: state.p, verdict: state.verdict)
        guard profile != .semanticRemoved, let sm = SemanticTiles.map(s.cgImage, config: s.config) else { return nil }
        state.semanticMajority = sm.majority
        state.semanticEvaluated = true
        let semVerdict = sm.majority > 0.5 ? "generated" : "real"

        PreviewTail.apply(&probe, &state, s, capture: cap, semanticMajority: sm.majority, canDecide: canDecide)

        let projection = PublicSurface.project(profile: profile, originalP: state.p, originalVerdict: state.verdict,
                                               probeP: probe.p, probeVerdict: probe.verdict, probeDecisive: probe.decisive)
        state.p = projection.p
        state.verdict = projection.verdict
        state.semanticDecisive = projection.decisive
        state.previewDecisive = canDecide && probe.previewDecisive
        state.stack.append(SpecialistContribution(name: "semantic-tiles", pAI: sm.majority, verdict: semVerdict,
                                                  weight: canDecide ? (semVerdict == state.verdict ? 1.0 : 0.25) : 0.0))
        return sm.grid
    }
}
