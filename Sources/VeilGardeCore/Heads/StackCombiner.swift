//
//  StackCombiner.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The combiner the first revision runs: on a capture-absent image it pools the anchor
//        member's P(AI) (the camera head's, or the screenshot head's when the gate fired) with the
//        evidence members it names into one P(AI). Evidence adds bounded generated evidence only (a
//        member saying "real" adds nothing), and when every evidence member reads real a rescue
//        pulls an unsure anchor down. A saturated member can never overturn a confident anchor.
//  PIN:  The file is version 1, keyed by member name:
//          {"model": "stack_combiner", "version": 1, "w0",
//           "anchor": {"cap", "w", "gate_ceiling"}, "evidence": [{"member", "w"}], "evidence_cap",
//           "rescue": {"w"}, "threshold", "note"}
//        The arithmetic, in Float, the evidence summed in the file's order:
//          lg(q, c) = clip(logit(clip(q, 1e-4, 1 − 1e-4)), ±c)
//          z = w0 + anchor.w·lg(a, anchor.cap) + Σ evidence[k].w·max(0, l_k),  l = lg(e_k, evidence_cap)
//          if a < gate_ceiling: z −= rescue.w·max(0, −max l)
//          p = σ(z), generated iff p > 0.5
//        Shipped: stack_combiner.json, the fit of 2026-10-21 over the camera head's capture-absent
//        store rows (anchor cap 4, evidence cap 2, gate 0.75; evidence art, blur, human).
//

import Foundation

public struct StackCombiner: Codable, Sendable, Equatable {
    public struct Anchor: Codable, Sendable, Equatable {
        public var cap: Float
        public var w: Float
        /// The rescue acts only while the anchor reads below this.
        public var gateCeiling: Float

        public init(cap: Float = 4, w: Float, gateCeiling: Float = 0.75) {
            self.cap = cap
            self.w = w
            self.gateCeiling = gateCeiling
        }

        enum CodingKeys: String, CodingKey {
            case cap, w
            case gateCeiling = "gate_ceiling"
        }
    }

    public struct Evidence: Codable, Sendable, Equatable {
        /// The stack member whose P(AI) this term reads.
        public var member: String
        public var w: Float

        public init(member: String, w: Float) {
            self.member = member
            self.w = w
        }
    }

    public struct Rescue: Codable, Sendable, Equatable {
        public var w: Float

        public init(w: Float) { self.w = w }
    }

    public static let modelName = "stack_combiner"
    public static let currentVersion = 1

    public var model: String
    public var version: Int
    public var w0: Float
    public var anchor: Anchor
    /// The evidence members, in the order their terms are summed.
    public var evidence: [Evidence]
    public var evidenceCap: Float
    public var rescue: Rescue
    public var threshold: Float?
    public var note: String?

    public init(w0: Float, anchor: Anchor, evidence: [Evidence], evidenceCap: Float = 2, rescue: Rescue, threshold: Float? = 0.5, note: String? = nil) {
        self.model = Self.modelName
        self.version = Self.currentVersion
        self.w0 = w0
        self.anchor = anchor
        self.evidence = evidence
        self.evidenceCap = evidenceCap
        self.rescue = rescue
        self.threshold = threshold
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case model, version, w0, anchor, evidence, rescue, threshold, note
        case evidenceCap = "evidence_cap"
    }

    public static func load(_ url: URL) throws -> StackCombiner {
        let combiner: StackCombiner
        do {
            combiner = try JSONDecoder().decode(StackCombiner.self, from: Data(contentsOf: url))
        } catch {
            throw VeilGardeFailure.data("not a stack combiner of version \(currentVersion): \(url.lastPathComponent): \(error)",
                                        hint: "refit the combiner with `veilgarde train combiner`")
        }
        guard combiner.model == modelName, combiner.version == currentVersion else {
            throw VeilGardeFailure.data("\(url.lastPathComponent) is \(combiner.model) version \(combiner.version), not \(modelName) version \(currentVersion)",
                                        hint: "refit the combiner with `veilgarde train combiner`")
        }
        return combiner
    }

    /// The members whose P(AI) the evidence terms read, in summation order.
    public var evidenceMembers: [String] { evidence.map(\.member) }

    /// The bounded logit.
    public func lg(_ q: Float, _ cap: Float) -> Float {
        let r = min(max(q, 1e-4), 1 - 1e-4)
        return min(max(log(r / (1 - r)), -cap), cap)
    }

    /// The evidence members' bounded logits.
    public func evidenceLogits(_ evidence: [Float]) -> [Float] { evidence.map { lg($0, evidenceCap) } }

    /// The pooled P(AI) from the anchor's P(AI) and the evidence members', in `evidenceMembers` order.
    public func pool(anchor a: Float, evidence e: [Float]) -> Float {
        var z = w0 + anchor.w * lg(a, anchor.cap)
        let ls = evidenceLogits(e)
        var maxLogit = -evidenceCap
        for (k, l) in ls.enumerated() {
            maxLogit = max(maxLogit, l)
            if k < evidence.count { z += evidence[k].w * max(0, l) }
        }
        if a < anchor.gateCeiling { z -= rescue.w * max(0, -maxLogit) }
        return 1 / (1 + exp(-z))
    }

    /// An evidence member's material influence on the verdict: its generated push, or, when the
    /// rescue is active (every evidence member reads real and the anchor is under the gate), the
    /// shared rescue pull.
    public func contribution(_ k: Int, anchor a: Float, evidence e: [Float]) -> Float {
        let ls = evidenceLogits(e)
        let l = ls[k]
        if l > 0 { return (k < evidence.count ? evidence[k].w : 0) * l }
        let maxLogit = ls.reduce(-evidenceCap, max)
        return (a < anchor.gateCeiling && maxLogit < 0) ? rescue.w * (-maxLogit) : 0
    }
}

/// The combiner as the trainer writes it: the same keys, numbers in Double.
public struct CombinerFile: Codable, Sendable, Equatable {
    public struct Anchor: Codable, Sendable, Equatable {
        public var cap: Double = 4
        public var w: Double
        public var gateCeiling: Double = 0.75

        public init(w: Double) { self.w = w }

        enum CodingKeys: String, CodingKey {
            case cap, w
            case gateCeiling = "gate_ceiling"
        }
    }

    public struct Evidence: Codable, Sendable, Equatable {
        public var member: String
        public var w: Double

        public init(member: String, w: Double) {
            self.member = member
            self.w = w
        }
    }

    public struct Rescue: Codable, Sendable, Equatable {
        public var w: Double

        public init(w: Double) { self.w = w }
    }

    public var model = StackCombiner.modelName
    public var version = StackCombiner.currentVersion
    public var w0: Double
    public var anchor: Anchor
    public var evidence: [Evidence]
    public var evidenceCap: Double = 2
    public var rescue: Rescue
    public var threshold: Double = 0.5
    public var note: String

    public init(w0: Double, anchor: Anchor, evidence: [Evidence], rescue: Rescue, note: String) {
        self.w0 = w0
        self.anchor = anchor
        self.evidence = evidence
        self.rescue = rescue
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case model, version, w0, anchor, evidence, rescue, threshold, note
        case evidenceCap = "evidence_cap"
    }

    /// The runtime combiner this file loads as.
    public func combiner() throws -> StackCombiner {
        try JSONDecoder().decode(StackCombiner.self, from: JSONCoding.prettyEncoder().encode(self))
    }
}
