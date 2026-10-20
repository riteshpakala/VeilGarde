//
//  AtlasPriors.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The three atlas category specialists, cross-domain "this is AI-generated" priors on the
//        normalized embedding: art (AI art against museum and human art), blur (generative blur
//        against optical blur), human (photoreal AI people against real portraits). Each is
//        recorded in the stack; the combiner pools them.
//  PIN:  Garde's atlas specialists: a prior "fires" at P ≥ 0.80 (the legacy override when no
//        combiner ships); its row weighs 1 when firing, 0.25 when consulted. Order art, blur,
//        human is the combiner's w_gen order. Inert when its head is not in the bundle.
//

enum AtlasPriors {
    static let fireThreshold: Float = 0.80
    static let kinds: [(name: String, kind: HeadKind)] = [("art", .art), ("blur", .blur), ("human", .human)]

    static func prior(_ name: String, _ kind: HeadKind, _ s: DetectionSignals) -> (contribution: SpecialistContribution, fires: Bool)? {
        guard let head = HeadRegistry.shared.head(kind, in: s.config.bundle), let emb = try? s.dinoNorm() else { return nil }
        let p = head.pAI(emb)
        let fires = p >= fireThreshold
        return (SpecialistContribution(name: name, pAI: p, verdict: p > head.threshold ? "generated" : "real", weight: fires ? 1.0 : 0.25), fires)
    }

    /// Art, blur, human, skipping any head the bundle lacks.
    static func evaluate(_ s: DetectionSignals) -> [(contribution: SpecialistContribution, fires: Bool)] {
        kinds.compactMap { prior($0.name, $0.kind, s) }
    }
}
