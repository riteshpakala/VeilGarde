//
//  StackCombiner.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The stack combiner (v3 asymmetric evidence pooling): on a capture-absent image it pools
//        the fusion base with the art, blur and human heads into one P(AI), and, when a combiner
//        file asks for it, an art-pair head adjudicating the art head (the shipped one does not).
//        Heads add bounded GEN evidence only (a head saying "real" adds nothing), and all heads
//        agreeing "real" can mount a consensus rescue when the base is uncertain. A saturated head
//        can never overturn a confident base.
//  PIN:  The reference's pool and contribution, without the noiseprint term it carried until
//        2026-10-21:
//          lg(q, c) = clip(logit(clip(q, 1e-4, 1 − 1e-4)), ±c)
//          z = w0 + w_base·lg(base, cap_base) + Σ w_gen[k]·max(0, l_k),  l = lg(head_k, cap_head)
//          l_art = min(l_art, lg(pair, cap_head))                        when pair_adjudicates
//          if base < gate_ceiling: z −= w_rescue·max(0, −max l)
//          p = σ(z), generated iff p > 0.5
//        Shipped: stack_combiner_v3.json, refit on the store on 2026-10-21 over the fusion head that
//        reads DINOv2 and capture (caps 4/2, gate 0.75, no art-pair adjudication). A file that still
//        carries a noiseprint weight (w_np) is refused. Arithmetic in Float.
//

import Foundation

public struct StackCombiner: Codable, Sendable, Equatable {
    public var w0: Float
    public var wBase: Float
    /// Per-head gen-evidence weights, in HeadKind.combinerOrder (art, blur, human), all ≥ 0.
    public var wGen: [Float]
    public var wRescue: Float
    public var capBase: Float
    public var capHead: Float
    public var gateCeiling: Float
    /// When true, the art logit is min(l_art, l_pair).
    public var pairAdjudicates: Bool?

    public init(w0: Float, wBase: Float, wGen: [Float], wRescue: Float, capBase: Float = 4, capHead: Float = 2,
                gateCeiling: Float = 0.75, pairAdjudicates: Bool? = true) {
        self.w0 = w0
        self.wBase = wBase
        self.wGen = wGen
        self.wRescue = wRescue
        self.capBase = capBase
        self.capHead = capHead
        self.gateCeiling = gateCeiling
        self.pairAdjudicates = pairAdjudicates
    }

    enum CodingKeys: String, CodingKey {
        case w0
        case wBase = "w_base"
        case wGen = "w_gen"
        case wRescue = "w_rescue"
        case capBase = "cap_base"
        case capHead = "cap_head"
        case gateCeiling = "gate_ceiling"
        case pairAdjudicates = "pair_adjudicates"
    }

    public static func load(_ url: URL) throws -> StackCombiner {
        let data: Data
        let combiner: StackCombiner
        do {
            data = try Data(contentsOf: url)
            combiner = try JSONDecoder().decode(StackCombiner.self, from: data)
        } catch {
            throw VeilGardeFailure.data("not a stack combiner: \(url.lastPathComponent): \(error)")
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["w_np"] != nil {
            throw VeilGardeFailure.data("the combiner \(url.lastPathComponent) carries a noiseprint term (w_np); the noiseprint left the detector on 2026-10-21",
                                        hint: "refit the combiner with `veilgarde train combine`")
        }
        return combiner
    }

    /// The bounded logit.
    public func lg(_ q: Float, _ cap: Float) -> Float {
        let r = min(max(q, 1e-4), 1 - 1e-4)
        return min(max(log(r / (1 - r)), -cap), cap)
    }

    /// Effective per-head logits: the art head (k = 0) adjudicated by the pairwise real-art head
    /// by min-composition, which can only cancel an art fire, never create one.
    public func headLogits(_ heads: [Float], pairAI: Float?) -> [Float] {
        var ls = heads.map { lg($0, capHead) }
        if pairAdjudicates == true, let pa = pairAI, !ls.isEmpty {
            ls[0] = min(ls[0], lg(pa, capHead))
        }
        return ls
    }

    /// The pooled P(AI).
    public func pool(base: Float, heads: [Float], pairAI: Float? = nil) -> Float {
        var z = w0 + wBase * lg(base, capBase)
        let ls = headLogits(heads, pairAI: pairAI)
        var maxHeadLogit = -capHead
        for (k, l) in ls.enumerated() {
            maxHeadLogit = max(maxHeadLogit, l)
            if k < wGen.count { z += wGen[k] * max(0, l) }
        }
        if base < gateCeiling { z -= wRescue * max(0, -maxHeadLogit) }
        return 1 / (1 + exp(-z))
    }

    /// A head's material influence on the verdict: its gen push, or, when a rescue is active (every
    /// head reads real and the base is under the gate), the shared rescue pull. Drives the
    /// specialist row's weight (filled above 0.5).
    public func contribution(_ k: Int, base: Float, heads: [Float], pairAI: Float? = nil) -> Float {
        let ls = headLogits(heads, pairAI: pairAI)
        let l = ls[k]
        if l > 0 { return (k < wGen.count ? wGen[k] : 0) * l }
        let maxHeadLogit = ls.reduce(-capHead, max)
        return (base < gateCeiling && maxHeadLogit < 0) ? wRescue * (-maxHeadLogit) : 0
    }
}

/// The combiner as the trainer writes it: the deployed schema, numbers in Double.
public struct CombinerFile: Codable, Sendable, Equatable {
    public var model = "stack_combiner"
    public var version = 3
    public var formula = "asymmetric"
    public var inputs = ["base", "art_gen", "blur_gen", "human_gen", "rescue"]
    public var w0: Double
    public var wBase: Double
    public var wGen: [Double]
    public var wRescue: Double
    public var pairAdjudicates = true
    public var capBase: Double = 4
    public var capHead: Double = 2
    public var gateCeiling: Double = 0.75
    public var threshold: Double = 0.5
    public var note: String

    public init(w0: Double, wBase: Double, wGen: [Double], wRescue: Double, note: String) {
        self.w0 = w0
        self.wBase = wBase
        self.wGen = wGen
        self.wRescue = wRescue
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case model, version, formula, inputs, w0, threshold, note
        case wBase = "w_base"
        case wGen = "w_gen"
        case wRescue = "w_rescue"
        case pairAdjudicates = "pair_adjudicates"
        case capBase = "cap_base"
        case capHead = "cap_head"
        case gateCeiling = "gate_ceiling"
    }

    /// The runtime combiner this file loads as.
    public func combiner() throws -> StackCombiner {
        try JSONDecoder().decode(StackCombiner.self, from: JSONCoding.prettyEncoder().encode(self))
    }
}
