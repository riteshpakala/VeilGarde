//
//  PreviewTail.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The preview-tail revision (v3.4, live): sub-512 images (capture invalid) are a
//        physics-empty regime where the camera head learned "small ⇒ AI". When such an image reads
//        generated with a clean semantic vote (majority ≤ 0.15), flip it to real only if the
//        preview member reads ≤ 0.45 and the camera member's p_neutral reads ≤ 0.30.
//  PIN:  A strict tail rescue, not a regime swap: OR-policies raised real false positives to
//        20–27% and were rejected (the research record, 2026-07-17, quoted). The flip is committed
//        only under the `.control` semantic profile (PublicSurface.project); the diagnostic profile
//        records that it fired without moving the verdict, and without the semantic tiles it never
//        arms.
//

public struct PreviewTail: Revision {
    public let name = "preview-tail"

    public init() {}

    public func apply(_ v: inout WorkingVerdict, stack: [MemberOutput], signals s: DetectionSignals, pipeline: Pipeline) throws -> RevisionRecord {
        let valid = stack.member("capture")?.flag("valid") ?? false
        let majority = stack.member("semantic-tiles")?.number("majority")
        guard !valid, v.prediction == "generated", let m = majority, m <= 0.15 else {
            return RevisionRecord(name: name, applied: false, p: v.p, prediction: v.prediction,
                                  fields: [Field("majority", majority.map { .number($0) } ?? .absent), Field("triggered", .flag(false)), Field("fires", .flag(false))])
        }
        let phv = stack.member("preview")?.p ?? -1
        let triggered = phv >= 0 && phv <= Specialist.previewCut
        let pn = triggered ? stack.member("camera")?.number("p_neutral") : nil
        let fires = triggered && (pn ?? 1.0) <= 0.30
        var probeP = v.p, probeVerdict = v.prediction
        if fires, let pn {
            probeVerdict = "real"
            probeP = min(probeP, pn)
        }
        let projection = PublicSurface.project(profile: s.config.semanticResponsibility, originalP: v.p, originalVerdict: v.prediction,
                                               probeP: probeP, probeVerdict: probeVerdict, probeDecisive: fires)
        v.p = projection.p
        v.prediction = projection.verdict
        return RevisionRecord(name: name, applied: projection.decisive, p: v.p, prediction: v.prediction,
                              fields: [Field("majority", .number(m)), Field("triggered", .flag(triggered)), Field("fires", .flag(fires))])
    }
}
