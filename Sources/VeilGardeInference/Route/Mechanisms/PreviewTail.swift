//
//  PreviewTail.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The preview-tail arbiter (v3.4, live): sub-512 images (capture invalid) are a physics-empty
//        regime where the base learned "small ⇒ AI". When such an image reads generated with a
//        clean semantic vote (≤ 0.15), flip to real only if the preview content head reads ≤ 0.45
//        and the frozen reference with the capture shortcut neutralized reads ≤ 0.30.
//  PIN:  Garde's preview block, unchanged, cheap gates first: the extra warp pass runs only on the
//        rare full-conflict path. A strict tail rescue, not a regime swap: OR-policies raised real
//        false positives to 20–27% and were rejected (the research record, 2026-07-17, quoted). Two rows: the head's
//        read (0.25) and the arbiter (1 when it fires).
//

enum PreviewTail {
    static func apply(_ chain: inout SemanticChain.Probe, _ state: inout RouteState, _ s: DetectionSignals, capture cap: CaptureSignature,
                      semanticMajority: Float, canDecide: Bool) {
        guard !cap.valid, chain.verdict == "generated", semanticMajority <= 0.15 else { return }
        state.semanticTriggered = true
        state.previewEvaluated = true
        let phv: Float = {
            guard let h = HeadRegistry.shared.head(.preview, in: s.config.bundle), let emb = try? s.dinoNorm() else { return -1 }
            return h.pAI(emb)
        }()
        state.previewTriggered = phv >= 0 && phv <= 0.45
        let pn = (phv >= 0 && phv <= 0.45) ? FusionReference.neutralizedBaseP(s) : nil
        let fires = phv >= 0 && phv <= 0.45 && (pn ?? 1.0) <= 0.30
        chain.previewDecisive = fires
        chain.decisive = chain.decisive || fires
        if phv >= 0 {
            state.stack.append(SpecialistContribution(name: "preview-head", pAI: phv, verdict: phv <= 0.45 ? "real" : "generated", weight: canDecide ? 0.25 : 0.0))
        }
        state.stack.append(SpecialistContribution(name: "preview-arbiter", pAI: pn ?? phv, verdict: fires ? "real" : "unconfirmed",
                                                  weight: canDecide ? (fires ? 1.0 : 0.25) : 0.0))
        if fires, let pn {
            chain.verdict = "real"
            chain.p = min(chain.p, pn)
        }
    }
}
