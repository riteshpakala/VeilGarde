//
//  FusionTrainer.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The fusion head, the base verdict for every image without a capture signature: a
//        boosted classifier over a FusionLayout's row, [dino_fusion(384) | cap(9)] = 393 or
//        [dino_fusion(384) | dino_norm(384) | cap(9)] = 777. Trained from scratch, or (the
//        flywheel's only base-moving step) continued from the live head by appending trees so the
//        parent's trees stay byte for byte.
//  PIN:  The reference's warm-start corpus and weights: every store row that is not golden, not
//        NSFW and carries dino_fusion, ordered by id; weight w_new_gen on generated rows from
//        new-generator shards (scrape_*, acquire_*), 0.7 on gen_family flux2-klein-4b, ×w_preview on
//        preview_aug, ×3 on emphasized ids. Warm start: +80 trees, depth 5, η 0.03, subsample 0.8,
//        colsample_bytree 0.8 (the weekly script). Scratch: 500 trees, depth 5, η 0.04, subsample
//        0.8, colsample_bytree 0.8. Two changes from the Python trainer, on purpose: 30% of the
//        new-generator rows (StableSplit "fusion-held:v1" on the id) are held out of training so
//        their recall is honest; and an evaluation twin, fitted the same way on the training rows
//        outside a 10% hash holdout (StableSplit "fusion-eval:v1"), is scored on that holdout so a
//        scratch fit reports a held-out AUC. The written head trains on every training row; the
//        twin is measurement only. A warm start needs a parent of the same width; recall and
//        agreement against a parent are measured only when it reads the same columns. Missing
//        values stay NaN and go right, as at inference. For the combiner, `outOfFold` refits a
//        scratch head k times, each without one fold of rows (StableSplit "fusion-oof:v1"), so
//        every row's base is the prediction of a head that never trained on it.
//

import Foundation
import VeilGardeCore

public enum FusionMode: Codable, Sendable, Equatable {
    case scratch(trees: Int, eta: Double)
    case warmStart(add: Int, eta: Double)

    public static let flywheel = FusionMode.warmStart(add: 80, eta: 0.03)
    public static let fromScratch = FusionMode.scratch(trees: 500, eta: 0.04)
}

public struct FusionSettings: Codable, Sendable, Equatable {
    public var mode: FusionMode = .flywheel
    public var maxDepth = 5
    public var subsample = 0.8
    public var colsample = 0.8
    public var seed: UInt64 = 0
    public var newGeneratorWeight = 1.0
    public var fluxWeight = 0.7
    public var previewWeight = 1.0
    public var emphasize: [String] = []
    public var emphasizeWeight = 3.0
    /// Shard-name prefixes whose generated rows are new-generator rows.
    public var newGeneratorShards = ["scrape_", "acquire_"]
    public var holdoutFraction = 0.3
    /// The share of rows the evaluation twin holds out (0 skips the twin).
    public var evaluationFraction = 0.1
    /// The row's layout; nil is `.dinoCapture`, as every recipe written before 2026-10-21 meant.
    public var layout: FusionLayout? = nil

    public init() {}

    public var resolvedLayout: FusionLayout { layout ?? .dinoCapture }
}

public struct FusionDataset: Sendable {
    public var ids: [String]
    public var data: BoostDataset
    public var isNewGenerator: [Bool]
    public var isHeldOut: [Bool]
    /// Rows the evaluation twin holds out (StableSplit "fusion-eval:v1").
    public var isEvaluation: [Bool]

    public static func assemble(_ store: FeatureStore, settings: FusionSettings) throws -> FusionDataset {
        let layout = settings.resolvedLayout
        let selection = try store.select(columns: Set(layout.columns)) { !$0.golden && !$0.nsfw }
        var order = (0..<selection.count).filter { selection.vector(.dinoFusion, row: $0).first?.isFinite ?? false }
        order.sort { selection.rows[$0].id < selection.rows[$1].id }
        let emphasized = Set(settings.emphasize)
        var x: [Float] = [], y: [Float] = [], w: [Float] = [], ids: [String] = [], newGen: [Bool] = [], held: [Bool] = [], eval: [Bool] = []
        x.reserveCapacity(order.count * layout.width)
        for i in order {
            let row = selection.rows[i]
            for column in layout.columns { x.append(contentsOf: selection.vector(column, row: i)) }
            y.append(Float(row.label))
            let isNew = row.isGenerated && settings.newGeneratorShards.contains { selection.shards[i].hasPrefix($0) }
            var weight = isNew ? settings.newGeneratorWeight : (row.genFamily == "flux2-klein-4b" ? settings.fluxWeight : 1)
            if row.source == "preview_aug" { weight *= settings.previewWeight }
            if emphasized.contains(row.id) { weight *= settings.emphasizeWeight }
            w.append(Float(weight))
            ids.append(row.id)
            newGen.append(isNew)
            held.append(isNew && StableSplit.isHoldout(row.id, salt: "fusion-held:v1", fraction: settings.holdoutFraction))
            eval.append(settings.evaluationFraction > 0 && StableSplit.isHoldout(row.id, salt: "fusion-eval:v1", fraction: settings.evaluationFraction))
        }
        return FusionDataset(ids: ids, data: BoostDataset(x: x, y: y, weight: w, features: layout.width),
                             isNewGenerator: newGen, isHeldOut: held, isEvaluation: eval)
    }

    public func subset(_ keep: (Int) -> Bool) -> BoostDataset {
        let f = data.features
        var x: [Float] = [], y: [Float] = [], w: [Float] = []
        for i in 0..<data.count where keep(i) {
            x.append(contentsOf: data.x[(i * f)..<((i + 1) * f)])
            y.append(data.y[i])
            w.append(data.weight?[i] ?? 1)
        }
        return BoostDataset(x: x, y: y, weight: w, features: f)
    }
}

public struct FusionReport: Codable, Sendable, Equatable {
    public var rows: Int
    public var trainedOn: Int
    public var newGeneratorRows: Int
    public var heldOutRows: Int
    public var heldOutRecallParent: Double?
    public var heldOutRecallCandidate: Double?
    /// The share of all corpus rows whose call at 0.5 the candidate and the parent agree on.
    public var agreementWithParent: Double?
    public var trees: Int
    public var inheritedTrees: Int
    /// The parent reads the same columns, so its recall and the agreement were measured.
    public var parentComparable: Bool
    /// The evaluation twin: rows it held out, and on them its AUC, its real false-positive rate and
    /// its generated recall at 0.5.
    public var evaluationRows: Int
    public var evaluationAUC: Double?
    public var evaluationRealFPR: Double?
    public var evaluationGeneratedRecall: Double?
    public var evaluationNote: String
    public var seconds: Double
}

/// Each fusion row's base from a head that never trained on it, by k folds.
public struct OutOfFoldBase: Codable, Sendable, Equatable {
    public static let file = "fusion/oof_base.json"
    public static let salt = "fusion-oof:v1"
    public var folds: Int
    /// The SHA-256 of the head these folds stand in for.
    public var headSHA256: String
    public var settings: FusionSettings
    public var predictions: [String: Double]

    public static func fold(_ id: String, folds: Int) -> Int { min(folds - 1, Int(StableSplit.unit(id, salt: salt) * Double(folds))) }
}

public enum FusionTrainer {
    /// Every row's prediction by a head refit, with `settings`, on the training rows outside the
    /// row's fold. A scratch fit only: a warm start's parent saw every row.
    public static func outOfFold(_ dataset: FusionDataset, settings: FusionSettings, folds: Int,
                                 note: (String) -> Void = { _ in }) throws -> [String: Double] {
        guard folds >= 2 else { throw VeilGardeFailure.usage("out-of-fold predictions need at least 2 folds, not \(folds)") }
        guard case .scratch(let trees, let eta) = settings.mode else {
            throw VeilGardeFailure.usage("out-of-fold base predictions need a scratch fusion head: a warm start's parent trained on every row")
        }
        var params = BoostParams(maxDepth: settings.maxDepth, subsample: settings.subsample, colsampleByTree: settings.colsample, seed: settings.seed)
        params.trees = trees
        params.eta = eta
        let fold = dataset.ids.map { OutOfFoldBase.fold($0, folds: folds) }
        var out: [String: Double] = [:]
        out.reserveCapacity(dataset.ids.count)
        for k in 0..<folds {
            let training = dataset.subset { !dataset.isHeldOut[$0] && fold[$0] != k }
            note("fusion: out-of-fold head \(k + 1) of \(folds) on \(training.count) rows")
            let model = BoostTrainer.train(training, params: params, warmStart: nil, featureNames: []).model
            for i in 0..<dataset.data.count where fold[i] == k { out[dataset.ids[i]] = Double(model.predict(dataset.data.row(i))) }
        }
        return out
    }

    public static func train(_ dataset: FusionDataset, settings: FusionSettings, parent: GBDTModel?,
                             note: (String) -> Void = { _ in }) throws -> (model: GBDTModel, report: FusionReport) {
        let started = Date()
        let training = dataset.subset { !dataset.isHeldOut[$0] }
        var params = BoostParams(maxDepth: settings.maxDepth, subsample: settings.subsample, colsampleByTree: settings.colsample, seed: settings.seed)
        var warm: GBDTModel? = nil
        switch settings.mode {
        case .scratch(let trees, let eta):
            params.trees = trees
            params.eta = eta
        case .warmStart(let add, let eta):
            guard let parent else { throw VeilGardeFailure.missing("a warm start needs the parent fusion head") }
            guard parent.featureCount == dataset.data.features else {
                throw VeilGardeFailure.data("the parent fusion head reads \(parent.featureCount) features; the store's fusion rows have \(dataset.data.features)",
                                            hint: "train the fusion head from scratch")
            }
            params.trees = add
            params.eta = eta
            warm = parent
        }
        let comparable = parent.map { $0.featureCount == dataset.data.features } ?? false

        // The evaluation twin: the same fit without the evaluation rows, scored on them.
        let evalRows = (0..<dataset.data.count).filter { dataset.isEvaluation[$0] && !dataset.isHeldOut[$0] }
        var evalAUC: Double? = nil, evalFPR: Double? = nil, evalRecall: Double? = nil
        if !evalRows.isEmpty {
            let twinTraining = dataset.subset { !dataset.isHeldOut[$0] && !dataset.isEvaluation[$0] }
            note("fusion: evaluation twin on \(twinTraining.count) rows, \(evalRows.count) held out")
            let twin = BoostTrainer.train(twinTraining, params: params, warmStart: warm, featureNames: []).model
            let p = evalRows.map { twin.predict(dataset.data.row($0)) }
            let y = evalRows.map { dataset.data.y[$0] }
            let reals = zip(p, y).filter { $0.1 == 0 }, gens = zip(p, y).filter { $0.1 == 1 }
            if !reals.isEmpty && !gens.isEmpty { evalAUC = Metrics.auc(p, y) }
            if !reals.isEmpty { evalFPR = Double(reals.filter { $0.0 > 0.5 }.count) / Double(reals.count) }
            if !gens.isEmpty { evalRecall = Double(gens.filter { $0.0 >= 0.5 }.count) / Double(gens.count) }
        }

        note("fusion: \(training.count) rows to train on (\(dataset.isHeldOut.filter { $0 }.count) new-generator rows held out), \(params.trees) trees")
        let boost = BoostTrainer.train(training, params: params, warmStart: warm, featureNames: [], progress: { round in
            if (round.tree + 1 - (warm?.trees.count ?? 0)) % 20 == 0 { note("fusion: tree \(round.tree + 1)") }
        })
        let model = boost.model
        func recall(_ m: GBDTModel) -> Double? {
            let held = (0..<dataset.data.count).filter { dataset.isHeldOut[$0] }
            guard !held.isEmpty else { return nil }
            return Double(held.filter { m.predict(dataset.data.row($0)) >= 0.5 }.count) / Double(held.count)
        }
        var agreement: Double? = nil
        if let parent, comparable {
            var same = 0
            for i in 0..<dataset.data.count {
                let row = dataset.data.row(i)
                if (parent.predict(row) > 0.5) == (model.predict(row) > 0.5) { same += 1 }
            }
            agreement = Double(same) / Double(max(1, dataset.data.count))
        }
        let report = FusionReport(rows: dataset.data.count, trainedOn: training.count, newGeneratorRows: dataset.isNewGenerator.filter { $0 }.count,
                                  heldOutRows: dataset.isHeldOut.filter { $0 }.count,
                                  heldOutRecallParent: comparable ? parent.flatMap(recall) : nil,
                                  heldOutRecallCandidate: recall(model), agreementWithParent: agreement, trees: model.trees.count,
                                  inheritedTrees: boost.inheritedTrees, parentComparable: comparable, evaluationRows: evalRows.count,
                                  evaluationAUC: evalAUC, evaluationRealFPR: evalFPR, evaluationGeneratedRecall: evalRecall,
                                  evaluationNote: "measured on a twin fitted without these rows (StableSplit fusion-eval:v1); the written head trained on them",
                                  seconds: Date().timeIntervalSince(started))
        return (model, report)
    }
}
