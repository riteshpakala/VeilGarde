//
//  CapturePriors.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The first compounding step. A valid, present capture signature suppresses every gen-side
//        head (the combiner is skipped) and, on the screenshot domain only, pins the verdict to
//        real at P ≤ 0.10. Otherwise the art, blur and human priors and noiseprint are pooled by the
//        stack combiner into the weighted P(AI); with no combiner in the bundle, a firing prior
//        overrides (the legacy rule). An art-pair head adjudicates the art head only for a combiner
//        that asks for it; the shipped one does not.
//  PIN:  Garde's router, its capture/prior block, unchanged: a prior row weighs 1 when its
//        contribution exceeds 0.5; an art-pair row shows only when the combiner adjudicates and the
//        art head fired, and weighs 1 when it discounts that fire; the sensor (noiseprint) row carries 1 − P(camera) and
//        weighs 1 when its camera evidence is active (P(camera) > 0.5 under the gate); pooled
//        > 0.5 is generated, with no inconclusive band.
//

enum CapturePriors {
    static func apply(_ state: inout RouteState, _ s: DetectionSignals, domain: DetectionDomain, capture cap: CaptureSignature) {
        if cap.valid && cap.present {
            state.stack.append(SpecialistContribution(name: "capture", pAI: 0.05, verdict: "real", weight: 1.0))
            if domain == .screenshot { state.p = min(state.p, CaptureLaw.realCeiling); state.verdict = "real" }
            return
        }
        let priors = AtlasPriors.evaluate(s)
        if let comb = HeadRegistry.shared.combiner(in: s.config.bundle), priors.count == comb.wGen.count {
            let hp = priors.map { $0.contribution.pAI }
            let pairAI: Float? = {
                guard comb.pairAdjudicates == true, let h = HeadRegistry.shared.head(.artPair, in: s.config.bundle), let emb = try? s.dinoNorm() else { return nil }
                return h.pAI(emb)
            }()
            let np: Float? = comb.wNp != nil ? NoiseprintLens.score(s.cgImage) : nil
            let pooled = comb.pool(base: state.p, heads: hp, pairAI: pairAI, np: np)
            for (k, prior) in priors.enumerated() {
                let influence = comb.contribution(k, base: state.p, heads: hp, pairAI: pairAI)
                state.stack.append(SpecialistContribution(name: prior.contribution.name, pAI: prior.contribution.pAI,
                                                          verdict: prior.contribution.verdict, weight: influence > 0.5 ? 1.0 : 0.25))
            }
            if let pa = pairAI, !hp.isEmpty, hp[0] > 0.5 {
                state.stack.append(SpecialistContribution(name: "art-pair", pAI: pa, verdict: pa > 0.5 ? "ai-art" : "real-art", weight: pa < 0.5 ? 1.0 : 0.25))
            }
            if let pn = np {
                let active = pn > 0.5 && state.p < comb.gateCeiling
                state.stack.append(SpecialistContribution(name: "sensor", pAI: 1 - pn, verdict: pn > 0.5 ? "camera" : "no-signal", weight: active ? 1.0 : 0.25))
            }
            state.p = pooled
            state.verdict = pooled > 0.5 ? "generated" : "real"
        } else {
            for prior in priors {
                state.stack.append(prior.contribution)
                if prior.fires { state.p = max(state.p, prior.contribution.pAI); state.verdict = "generated" }
            }
        }
        if cap.valid { state.stack.append(SpecialistContribution(name: "capture", pAI: 0.5, verdict: "absent", weight: 0.0)) }
    }
}
