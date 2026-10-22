//
//  Specialist.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A specialist member: one linear head on the force-resized DINOv2 embedding, a take on
//        one sector of images. art (AI art against museum and human art), blur (generative blur
//        against optical blur), human (photoreal AI people against real portraits), preview
//        (small previews, where the camera head learned "small ⇒ AI"). One file serves every
//        such head; a new one is a head file in the bundle and one line in the pipeline.
//  PIN:  P(AI) is the head's; art, blur and human say generated above the head's threshold, preview
//        reads real at or below 0.45, the preview tail's cut. A head the bundle lacks leaves no
//        entry. The screenshot and semantic-tile heads have members of their own.
//

public struct Specialist: StackMember {
    /// The preview head's cut: at or below it the preview member reads real.
    public static let previewCut: Float = 0.45

    public let kind: HeadKind
    public var name: String { kind.rawValue }

    public init(_ kind: HeadKind) {
        precondition(kind != .screenshot && kind != .semtile, "the \(kind.rawValue) head has a member of its own")
        self.kind = kind
    }

    public func score(_ s: DetectionSignals) throws -> MemberOutput? {
        guard let head = HeadRegistry.shared.head(kind, in: s.config.bundle) else { return nil }
        let p = head.pAI(try s.dinoNorm())
        let verdict = kind == .preview ? (p <= Self.previewCut ? "real" : "generated") : (p > head.threshold ? "generated" : "real")
        return MemberOutput(name: name, p: p, verdict: verdict)
    }
}
