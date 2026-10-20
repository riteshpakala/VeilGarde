//
//  StackCombiner.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The stack combiner (v3 asymmetric evidence pooling): on a capture-absent image it pools
//        the fusion base with the art, blur and human heads and noiseprint into one P(AI), and, when a
//        combiner file asks for it, an art-pair head adjudicating the art head (the shipped one does not). Heads add bounded GEN evidence only (a head saying "real" adds
//        nothing), all heads agreeing "real" can mount a consensus rescue when the base is
//        uncertain, and noiseprint's camera evidence pulls toward real under the same gate. A
//        saturated head can never overturn a confident base.
//  PIN:  Garde's StackCombiner.pool and contribution, unchanged:
//          lg(q, c) = clip(logit(clip(q, 1e-4, 1 − 1e-4)), ±c)
//          z = w0 + w_base·lg(base, cap_base) + Σ w_gen[k]·max(0, l_k),  l = lg(head_k, cap_head)
//          l_art = min(l_art, lg(pair, cap_head))                        when pair_adjudicates
//          if base < gate_ceiling: z −= w_rescue·max(0, −max l);  z −= w_np·max(0, lg(np, cap_head))
//          p = σ(z), generated iff p > 0.5
//        Shipped: stack_combiner_v2.json, Garde's weights (w0 −0.6755, w_base 3.8205, w_gen [0, 0,
//        0.1967], w_rescue 0.5, w_np 0.8, caps 4/2, gate 0.75) with pair_adjudicates false: the pruning
//        study found the art-pair broke 19 store calls to fix 10. Arithmetic in Float, as Garde's.
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
    /// Noiseprint's camera-evidence weight (protect-real, ≥ 0). Absent in a v2 file.
    public var wNp: Float?
    /// When true, the art logit is min(l_art, l_pair).
    public var pairAdjudicates: Bool?

    public init(w0: Float, wBase: Float, wGen: [Float], wRescue: Float, capBase: Float = 4, capHead: Float = 2,
                gateCeiling: Float = 0.75, wNp: Float? = nil, pairAdjudicates: Bool? = true) {
        self.w0 = w0
        self.wBase = wBase
        self.wGen = wGen
        self.wRescue = wRescue
        self.capBase = capBase
        self.capHead = capHead
        self.gateCeiling = gateCeiling
        self.wNp = wNp
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
        case wNp = "w_np"
        case pairAdjudicates = "pair_adjudicates"
    }

    public static func load(_ url: URL) throws -> StackCombiner {
        do { return try JSONDecoder().decode(StackCombiner.self, from: Data(contentsOf: url)) } catch {
            throw VeilGardeFailure.data("not a stack combiner: \(url.lastPathComponent): \(error)")
        }
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
    public func pool(base: Float, heads: [Float], pairAI: Float? = nil, np: Float? = nil) -> Float {
        var z = w0 + wBase * lg(base, capBase)
        let ls = headLogits(heads, pairAI: pairAI)
        var maxHeadLogit = -capHead
        for (k, l) in ls.enumerated() {
            maxHeadLogit = max(maxHeadLogit, l)
            if k < wGen.count { z += wGen[k] * max(0, l) }
        }
        if base < gateCeiling {
            z -= wRescue * max(0, -maxHeadLogit)
            if let wn = wNp, let pn = np { z -= wn * max(0, lg(pn, capHead)) }
        }
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
    public var inputs = ["base", "art_gen", "blur_gen", "human_gen", "rescue", "noiseprint"]
    public var w0: Double
    public var wBase: Double
    public var wGen: [Double]
    public var wRescue: Double
    public var wNp: Double
    public var pairAdjudicates = true
    public var capBase: Double = 4
    public var capHead: Double = 2
    public var gateCeiling: Double = 0.75
    public var threshold: Double = 0.5
    public var note: String

    public init(w0: Double, wBase: Double, wGen: [Double], wRescue: Double, wNp: Double, note: String) {
        self.w0 = w0
        self.wBase = wBase
        self.wGen = wGen
        self.wRescue = wRescue
        self.wNp = wNp
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case model, version, formula, inputs, w0, threshold, note
        case wBase = "w_base"
        case wGen = "w_gen"
        case wRescue = "w_rescue"
        case wNp = "w_np"
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
