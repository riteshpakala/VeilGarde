//
//  WeeklyCandidates.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The weekly step: candidate heads (art, blur, human) and a warm-started camera head from
//        the whole store, trained on top of the live bundle into candidates/<id>/, measured
//        against live by the north-star agreement, and written up in REVIEW.md with the rule for
//        what to promote. Nothing here writes live/.
//  PIN:  The weekly script's recipe (the camera warm start +80 trees at η 0.03, w_gen 1.0; the
//        category heads from the store) and its review note's decision rule, with VeilGarde's
//        commands in place of the shell scripts.
//

import Foundation
import VeilGardeCore

public struct CandidatesOutcome: Sendable {
    public var candidate: CandidateBundle
    public var liveAgreement: AgreementReport
    public var candidateAgreement: AgreementReport
    public var review: URL
}

public enum WeeklyCandidates {
    public static func recipe(id: String) -> TrainingRecipe {
        TrainingRecipe(id: id) {
            CameraHead().warmStart(add: 80, eta: 0.03).newGeneratorWeight(1.0)
            for kind in HeadKind.flywheelCategories { SpecialistHead(kind).version("weekcand") }
        }
    }

    public static func run(_ recipe: TrainingRecipe, area: FlywheelArea, replace: Bool = false,
                           onEvent: @escaping (TrainingEvent) -> Void = { _ in }) throws -> CandidatesOutcome {
        let live = try area.liveBundle()
        let engine = TrainingEngine(area: area.area, parent: area.live, store: area.store, onEvent: onEvent)
        engine.replace = replace
        let outcome = try engine.train(recipe)
        let store = FeatureStore(directory: area.store)
        onEvent(.note("agreement: measuring the live bundle and the candidate on the store"))
        let liveAgreement = try Agreement.measure(live, store: store, label: "live")
        let candidateAgreement = try Agreement.measure(outcome.candidate.bundle, store: store, label: recipe.id)
        try Agreement.append(liveAgreement, to: area.metricsCSV)
        try Agreement.append(candidateAgreement, to: area.metricsCSV)
        try outcome.candidate.write(["live": liveAgreement, "candidate": candidateAgreement], as: "agreement.json")
        let review = outcome.candidate.root.appendingPathComponent("REVIEW.md")
        try reviewNote(recipe: recipe, outcome: outcome, live: liveAgreement, candidate: candidateAgreement).write(to: review, atomically: true, encoding: .utf8)
        return CandidatesOutcome(candidate: outcome.candidate, liveAgreement: liveAgreement, candidateAgreement: candidateAgreement, review: review)
    }

    static func reviewNote(recipe: TrainingRecipe, outcome: TrainingOutcome, live: AgreementReport, candidate: AgreementReport) -> String {
        let root = outcome.candidate.root.path
        func f(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "n/a" }
        var lines = ["# Candidate \(recipe.id)", "", "Trained on top of the live bundle, into `\(root)`. Nothing here is live until it is promoted.", ""]
        if let json = outcome.metrics["camera"], let data = json.data(using: .utf8),
           let camera = try? JSONDecoder().decode(CameraMetricsView.self, from: data) {
            lines += ["## The camera head (warm start)", "",
                      "- Held-out new-generator recall: \(f(camera.report.heldOutRecallParent)) live, \(f(camera.report.heldOutRecallCandidate)) candidate (\(camera.report.heldOutRows) rows held out).",
                      "- Agreement with the live head at 0.5: \(f(camera.report.agreementWithParent)).",
                      "- Trees: \(camera.report.inheritedTrees) kept byte for byte, \(camera.report.trees - camera.report.inheritedTrees) added.", ""]
        }
        lines += ["## The heads", ""]
        for kind in HeadKind.flywheelCategories {
            guard let json = outcome.metrics["head:\(kind.rawValue)"], let data = json.data(using: .utf8),
                  let h = try? JSONDecoder().decode(HeadReport.self, from: data) else { continue }
            let admitted = h.admitted.map { $0 ? "PASS" : "FAIL" } ?? "n/a"
            let block = h.admissionBlock08.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"
            lines.append(String(format: "- %@: test AUC %.4f (live head %@ on the same rows); admission block@0.8 %@ on %d golden reals: %@.",
                                kind.rawValue, h.testAUC, f(h.parent?.testAUC), block, h.admissionAnchors, admitted))
        }
        lines += ["", "## The north star (camera ↔ pooled agreement, on the store)", "",
                  "| | live | candidate |", "|---|---|---|",
                  "| agreement, all | \(f(live.agreementAll)) | \(f(candidate.agreementAll)) |",
                  "| agreement, camera | \(f(live.agreementCamera)) | \(f(candidate.agreementCamera)) |",
                  "| agreement, processed | \(f(live.agreementProcessed)) | \(f(candidate.agreementProcessed)) |",
                  "| camera AUC | \(f(live.cameraAUC)) | \(f(candidate.cameraAUC)) |",
                  "| pooled AUC | \(f(live.pooledAUC)) | \(f(candidate.pooledAUC)) |",
                  "| AUC gap | \(f(live.aucGap)) | \(f(candidate.aucGap)) |", "",
                  "## The decision rule (heads-only flywheel)", "",
                  "- **Head only**: the gap is in a class where the head already has authority (art, blur and human through w_gen; preview through its tail), and its admission line above is PASS. Ship it: `veilgarde flywheel promote <kind> --from \(root)`.",
                  "- **Head and camera**: the gap needs the pooled verdict to move further than a head's capped weight can carry it, or the store gained 500 or more new dino_fusion rows in the gap's category (the dilution law). Ship the camera head first, then the head: `veilgarde flywheel promote camera --from \(root)`.",
                  "", "Both run the battery: the camera head on its HARD groups, a head on all of them, ratchet and semantic floors included, because heads reach every revision. A failing battery restores the live bundle.", ""]
        return lines.joined(separator: "\n")
    }

    /// The camera head's metrics as the engine writes them, read back for the review.
    struct CameraMetricsView: Decodable { var report: CameraReport }
}
