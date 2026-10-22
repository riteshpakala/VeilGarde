//
//  Camera.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The camera member: the camera head, a booster over DINOv2's plain CLS embedding and the
//        nine capture values (393 columns), the detector's take on whether a camera made the image.
//        Its P(AI) is labelled at the config's operating point, 0.5 ± 0.04. It also reports
//        p_neutral, the same head with the capture-validity shortcut neutralized, which the
//        preview tail reads.
//  PIN:  Column order is CameraRow's. Neutralizing sets valid = 1 and native px = max(·, 576):
//        invalid-capture rows were 85.5% generated in the 2026-07-17 measurement and taught the
//        head "small ⇒ AI". The head is scored with Frigate's evaluator from the config's bundle.
//

public struct Camera: StackMember {
    public let name = "camera"

    public init() {}

    public func score(_ s: DetectionSignals) throws -> MemberOutput? {
        guard let url = s.config.bundle.url(.camera) else { throw VeilGardeFailure.missing("the bundle has no camera head") }
        let head = try TreeModelCache.shared.model(url)
        guard head.numFeatures == CameraRow.width else {
            throw VeilGardeFailure.data("the camera head reads \(head.numFeatures) features; its row is \(CameraRow.width) wide")
        }
        let dino = try s.dinoFusion()
        let capture = s.capture().features
        let p = head.predict(CameraRow(dino: dino, capture: capture).asVector)
        var neutral = capture.asVector
        neutral[1] = 1.0
        neutral[3] = max(neutral[3], 576.0)
        let pNeutral = head.predict(dino + neutral)
        return MemberOutput(name: name, p: p, verdict: s.config.decision.label(p), fields: [Field("p_neutral", .number(pNeutral))])
    }
}
