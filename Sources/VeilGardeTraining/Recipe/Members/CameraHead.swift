//
//  CameraHead.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The camera member's model as a recipe line: the camera head over the 393-column camera
//        row, from scratch or as a warm start of the parent's head (the flywheel's way), and how it
//        trains: the store's rows to CameraDataset, CameraTrainer's fit, the head written as
//        camera/camera.xgb.json with its metrics beside it.
//
//            CameraHead().warmStart(add: 80, eta: 0.03).newGeneratorWeight(1.0)
//
//  PIN:  A warm start needs a parent camera head of the row's width and records the parent's hash;
//        a scratch fit records none. The parent's recall and agreement are reported only when it
//        reads the same row.
//

import Foundation
import VeilGardeCore

public struct CameraHead: TrainableMember, Equatable {
    public static let recipeKind = "camera"
    public var settings = CameraSettings()

    public var name: String { "camera" }
    public var rank: Int { 0 }

    public init() {}

    private func with(_ change: (inout CameraHead) -> Void) -> CameraHead { var c = self; change(&c); return c }
    public func warmStart(add: Int = 80, eta: Double = 0.03) -> CameraHead { with { $0.settings.mode = .warmStart(add: add, eta: eta) } }
    public func scratch(trees: Int = 500, eta: Double = 0.04) -> CameraHead { with { $0.settings.mode = .scratch(trees: trees, eta: eta) } }
    public func newGeneratorWeight(_ w: Double) -> CameraHead { with { $0.settings.newGeneratorWeight = w } }
    public func previewWeight(_ w: Double) -> CameraHead { with { $0.settings.previewWeight = w } }
    public func emphasize(_ ids: [String], weight: Double = 3) -> CameraHead { with { $0.settings.emphasize = ids; $0.settings.emphasizeWeight = weight } }
    public func depth(_ d: Int) -> CameraHead { with { $0.settings.maxDepth = d } }

    /// What the candidate records beside the head.
    public struct Metrics: Codable {
        public var settings: CameraSettings
        public var parentSHA256: String?
        public var report: CameraReport
    }

    public func plan(in context: TrainingContext) throws -> ModelPlan {
        var p = ModelPlan(model: name, stages: [], refusal: context.storeMissing)
        let usable = context.rows.filter { !$0.row.golden && !$0.row.nsfw }
        let newGen = usable.filter { r in r.row.isGenerated && settings.newGeneratorShards.contains { r.shard.hasPrefix($0) } }.count
        let parentWidth: Int? = context.parent.manifest.artifact(.camera).flatMap {
            try? GBDTModel.load(context.parent.root.appendingPathComponent($0.file)).featureCount
        }
        let mode: String
        switch settings.mode {
        case .warmStart(let add, let eta):
            mode = "warm start: +\(add) trees at η \(eta) onto the parent's camera head \(context.parent.sha256(.camera)?.prefix(12) ?? "?")"
            if parentWidth == nil { p.refusal = "the parent bundle has no camera head to continue: train it from scratch" }
            if let w = parentWidth, w != CameraRow.width {
                p.refusal = "the parent's camera head reads \(w) features, the camera row \(CameraRow.width): train it from scratch"
            }
        case .scratch(let trees, let eta):
            mode = "from scratch: \(trees) trees at η \(eta)"
            if let w = parentWidth, w != CameraRow.width {
                p.notes.append("the parent's camera head reads \(w) features: no parent recall or agreement will be reported")
            }
        }
        p.stages = [
            StageDecision(.data, runs: true, "\(usable.count) store rows that are not golden or NSFW (those carrying dino_fusion), \(newGen) of them new-generator rows; \(CameraRow.width) columns, \(CameraRow.columns.map(\.rawValue).joined(separator: ", "))"),
            StageDecision(.fit, runs: true, mode + ", depth \(settings.maxDepth), subsample \(settings.subsample), colsample \(settings.colsample)"),
            StageDecision(.evaluate, runs: true, "recall on the \(Int(settings.holdoutFraction * 100))% of new-generator rows held out, agreement with the parent when it reads the same row, and an evaluation twin's AUC on a \(Int(settings.evaluationFraction * 100))% hash holdout"),
            StageDecision(.write, runs: true, "camera/camera.xgb.json"),
        ]
        return p
    }

    public func train(in run: TrainingRun) throws -> String {
        run.emit(.stage(model: name, .data))
        let dataset = try CameraDataset.assemble(run.store, settings: settings)
        let parentArtifact = run.candidate.manifest.artifact(.camera)
        let parentModel = try parentArtifact.map { try GBDTModel.load(run.candidate.root.appendingPathComponent($0.file)) }
        run.emit(.stage(model: name, .fit))
        let (model, report) = try CameraTrainer.train(dataset, settings: settings, parent: parentModel, note: { run.emit(.note($0)) })
        run.emit(.stage(model: name, .evaluate))
        run.emit(.note("camera: held-out new-generator recall " + [report.heldOutRecallParent, report.heldOutRecallCandidate]
            .map { $0.map { String(format: "%.3f", $0) } ?? "n/a" }.joined(separator: " (parent) → ") + " (candidate)"
            + (report.agreementWithParent.map { String(format: ", agreement %.4f", $0) } ?? "")
            + (report.evaluationAUC.map { String(format: "; the evaluation twin's AUC %.4f on %d held-out rows", $0, report.evaluationRows) } ?? "")))
        run.emit(.stage(model: name, .write))
        let isWarm: Bool
        if case .warmStart = settings.mode { isWarm = true } else { isWarm = false }
        try run.candidate.put(model.encodeXGBoostJSON(), as: "camera/camera.xgb.json", role: .camera, parent: isWarm ? parentArtifact?.sha256 : nil)
        return try run.record(Metrics(settings: settings, parentSHA256: parentArtifact?.sha256, report: report), model: name, as: "camera/metrics.json")
    }
}
