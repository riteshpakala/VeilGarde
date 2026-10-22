//
//  SpecialistHead.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A linear head as a recipe line: which store rows are its positives and negatives, its
//        regularization and admission, and how it trains: HeadTrainer's source-disjoint fit on the
//        store's dino_norm column, written as heads/<kind>/head.json with its recipe and metrics.
//
//            SpecialistHead(.human).regularization(C: 0.25)
//
//  PIN:  The shipped recipe for each kind: art, blur and human are generated rows of their category
//        against every real row, balanced, admitted at block@0.8 ≤ 10%; preview is generated
//        against real previews; screenshot is generated against real screenshots, C 1.0, no class
//        weight; semtile is refused (the store keeps no patch tokens).
//

import Foundation
import VeilGardeCore

public struct SpecialistHead: TrainableMember, Equatable {
    public static let recipeKind = "specialist"
    public var kind: HeadKind
    public var positives: RowFilter
    public var negatives: RowFilter
    public var settings = HeadSettings()

    public var name: String { "head:\(kind.rawValue)" }
    public var rank: Int { 1 }

    /// The shipped recipe for `kind`.
    public init(_ kind: HeadKind) {
        self.kind = kind
        switch kind {
        case .art, .blur, .human:
            positives = .generated(kind.rawValue); negatives = .allReal
        case .preview:
            positives = .generated("preview"); negatives = .real("preview"); settings.admission = false
        case .screenshot:
            positives = .generated("screenshot"); negatives = .real("screenshot"); settings.C = 1.0; settings.classWeight = .none
            settings.admission = false; settings.fireThreshold = nil
        case .semtile:
            positives = .generated("art"); negatives = .allReal; settings.admission = false
        }
    }

    private func with(_ change: (inout SpecialistHead) -> Void) -> SpecialistHead { var c = self; change(&c); return c }
    public func positives(_ f: RowFilter) -> SpecialistHead { with { $0.positives = f } }
    public func negatives(_ f: RowFilter) -> SpecialistHead { with { $0.negatives = f } }
    public func regularization(C: Double) -> SpecialistHead { with { $0.settings.C = C } }
    public func balanced(_ on: Bool = true) -> SpecialistHead { with { $0.settings.classWeight = on ? .balanced : .none } }
    public func version(_ v: String) -> SpecialistHead { with { $0.settings.version = v } }
    public func admission(_ on: Bool) -> SpecialistHead { with { $0.settings.admission = on } }

    public func plan(in context: TrainingContext) throws -> ModelPlan {
        var p = ModelPlan(model: name, stages: [], refusal: context.storeMissing)
        if let reason = HeadTrainer.refusal(kind, categories: Set(context.rows.map(\.row.category))) { p.refusal = reason }
        let usable = context.rows.filter { !$0.row.golden }
        let pos = usable.filter { positives.matches($0.row) }.count
        let neg = usable.filter { !positives.matches($0.row) && negatives.matches($0.row) }.count
        p.stages = [
            StageDecision(.data, runs: true, "\(pos) positives (\(positives.summary)) and \(neg) negatives (\(negatives.summary)), golden held out, those carrying dino_norm"),
            StageDecision(.fit, runs: true, "StandardScaler and logistic regression, C \(settings.C), class weight \(settings.classWeight.rawValue)"),
            StageDecision(.evaluate, runs: true, "test AUC on the source-disjoint 25% split; golden-real anchors' block at 0.5 and 0.8"
                          + (settings.admission ? "; admission at block@0.8 ≤ 0.10" : "")),
            StageDecision(.write, runs: true, "heads/\(kind.rawValue)/head.json"),
        ]
        return p
    }

    public func train(in run: TrainingRun) throws -> String {
        run.emit(.stage(model: name, .data))
        let selection = try run.dinoNormSelection()
        run.emit(.stage(model: name, .fit))
        let parentHead = try run.candidate.url(.head, head: kind).map { try LinearHead.load($0) }
        let (file, report) = try HeadTrainer.train(kind, positives: positives, negatives: negatives, settings: settings,
                                                   store: selection, parent: parentHead, note: { run.emit(.note($0)) })
        run.emit(.stage(model: name, .evaluate))
        func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a" }
        run.emit(.note(String(format: "head %@: test AUC %.4f (split by %@); golden-real block@0.8 %@", kind.rawValue, report.testAUC,
                              report.split.rawValue, pct(report.anchorBlock08))
            + (report.admitted.map { ($0 ? ", admitted" : ", NOT admitted") + " (block@0.8 \(pct(report.admissionBlock08)) on \(report.admissionAnchors) non-bsky golden reals, bar 10%)" } ?? "")
            + (report.parent.map { String(format: "; the parent's head on the same rows: test AUC %.4f, golden-real block@0.8 %@, admission block %@",
                                          $0.testAUC, pct($0.anchorBlock08), pct($0.admissionBlock08)) } ?? "")))
        run.emit(.stage(model: name, .write))
        let folder = "heads/\(kind.rawValue)"
        try run.candidate.put(try JSONCoding.prettyEncoder().encode(file), as: "\(folder)/head.json", role: .head, head: kind)
        try run.candidate.write(self, as: "\(folder)/recipe.json")
        return try run.record(report, model: name, as: "\(folder)/metrics.json")
    }
}
