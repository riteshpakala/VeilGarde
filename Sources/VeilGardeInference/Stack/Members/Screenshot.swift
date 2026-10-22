//
//  Screenshot.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The screenshot member: the flat-UI gate's three tells, whether they fire together, and the
//        screenshot content head's P(AI) on the force-resized embedding, the take of a head
//        trained on social-media screenshots, where the camera head false-positives. The combiner
//        anchors on it when the gate fires.
//  PIN:  The head's own threshold with the config's band labels its p; without a screenshot head in
//        the bundle the member reports the gate with no p. The head must read the shared 360×640
//        embedding (every shipped head does); one of another size is refused rather than fed the
//        wrong reading.
//

public struct Screenshot: StackMember {
    public let name = "screenshot"

    public init() {}

    public func score(_ s: DetectionSignals) throws -> MemberOutput? {
        let gate: [Field] = [Field("gate", .flag(s.gate.isScreenshot)), Field("grad_zero", .number(s.gate.gradZero)),
                             Field("flat_strict", .number(s.gate.flatStrict)), Field("top_color", .number(s.gate.topColor))]
        guard let head = HeadRegistry.shared.head(.screenshot, in: s.config.bundle) else {
            return MemberOutput(name: name, p: nil, verdict: "absent", fields: gate)
        }
        guard head.normW == 360, head.normH == 640 else {
            throw VeilGardeFailure.data("the screenshot head reads a \(head.normW)×\(head.normH) embedding; the shared signals hold the 360×640 one")
        }
        let p = head.pAI(try s.dinoNorm())
        let t = head.threshold
        let verdict = abs(p - t) < s.config.decision.band ? "inconclusive" : (p > t ? "generated" : "real")
        return MemberOutput(name: name, p: p, verdict: verdict, fields: gate + [Field("threshold", .number(t))])
    }
}
