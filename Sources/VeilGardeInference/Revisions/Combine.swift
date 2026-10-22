//
//  Combine.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The combiner revision, the first: it sets the verdict from the stack. It anchors on the
//        screenshot member when the flat-UI gate fired and on the camera member otherwise, and
//        takes the anchor's operating point. On an image with a present capture signature the
//        anchor stands and the generated-side evidence is silenced (under the screenshot anchor,
//        capped at P 0.10 and real). Otherwise the stack combiner pools the anchor with the
//        evidence members its file names.
//  PIN:  The pooled verdict is generated iff p > 0.5, with no inconclusive band. The evidence is
//        read by name in the combiner file's order and summed in it. A bundle without a combiner,
//        or a combiner naming a member the stack does not hold, is refused. Each evidence
//        member's influence is StackCombiner.contribution.
//

public struct Combine: Revision {
    public let name = "combiner"

    public init() {}

    public func apply(_ v: inout WorkingVerdict, stack: [MemberOutput], signals s: DetectionSignals, pipeline: Pipeline) throws -> RevisionRecord {
        guard let combiner = HeadRegistry.shared.combiner(in: s.config.bundle) else {
            throw VeilGardeFailure.missing("the bundle has no stack combiner")
        }
        let anchorName = s.gate.isScreenshot ? "screenshot" : "camera"
        let anchor = try stack.required(anchorName, by: name)
        guard let a = anchor.p else { throw VeilGardeFailure.missing("the \(anchorName) member has no P(AI): the bundle has no \(anchorName) head") }
        v.p = a
        v.prediction = anchor.verdict
        v.threshold = anchorName == "screenshot" ? (anchor.number("threshold") ?? s.config.decision.threshold) : s.config.decision.threshold
        v.band = s.config.decision.band

        let capture = try stack.required("capture", by: name)
        if capture.flag("valid") == true && capture.flag("present") == true {
            if anchorName == "screenshot" {
                v.p = min(v.p, CaptureLaw.realCeiling)
                v.prediction = "real"
            }
            return RevisionRecord(name: name, applied: true, p: v.p, prediction: v.prediction,
                                  fields: [Field("anchor", .text(anchorName)), Field("pooled", .absent), Field("influence", .absent)])
        }
        let evidence = try combiner.evidenceMembers.map { member -> Float in
            guard let p = try stack.required(member, by: name).p else { throw VeilGardeFailure.missing("the \(member) member has no P(AI)") }
            return p
        }
        let pooled = combiner.pool(anchor: a, evidence: evidence)
        var influence: [String: Float] = [:]
        for (k, member) in combiner.evidenceMembers.enumerated() { influence[member] = combiner.contribution(k, anchor: a, evidence: evidence) }
        v.p = pooled
        v.prediction = pooled > 0.5 ? "generated" : "real"
        return RevisionRecord(name: name, applied: true, p: v.p, prediction: v.prediction,
                              fields: [Field("anchor", .text(anchorName)), Field("pooled", .number(pooled)), Field("influence", .map(influence))])
    }
}
