//
//  FusionTrainer.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The fusion head, the base verdict for every image without a capture signature: a
//        boosted classifier over the 397-value row [warp | dino_fusion(384) | cap(9) | sharp(3)].
//        Trained from scratch, or (the flywheel's only base-moving step) continued from the live
//        head by appending trees so the parent's trees stay byte for byte.
//  PIN:  v199_warmstart.py's corpus and weights: every store row that is not golden, not NSFW and
//        carries dino_fusion, ordered by id; weight w_new_gen on generated rows from new-generator
//        shards (scrape_*), 0.7 on gen_family flux2-klein-4b, ×w_preview on preview_aug,
//        ×3 on emphasized ids. Warm start: +80 trees, depth 5, η 0.03, subsample 0.8,
//        colsample_bytree 0.8 (the weekly script). Scratch: 500 trees, depth 5, η 0.04, subsample 0.8,
//        colsample_bytree 0.8. One change from the Python trainer, on purpose: the new-generator rows it reported
//        recall on were also trained on; here 30% of them (StableSplit "fusion-held:v1" on the id)
//        are held out of training, so the recall is honest. Missing values stay NaN and go right,
//        as at inference. Rows whose warp column came from different warp models are refused
//        unless allowed: the fusion head would learn two scales as one.
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
    public var allowMixedWarp = false

    public init() {}
}

public struct FusionDataset: Sendable {
    public var ids: [String]
    public var data: BoostDataset
    public var isNewGenerator: [Bool]
    public var isHeldOut: [Bool]
    /// warp_model tag → rows ("unknown" for rows that do not say, as the seed store's do not).
    public var warpModels: [String: Int]

    public static func assemble(_ store: FeatureStore, settings: FusionSettings) throws -> FusionDataset {
        let selection = try store.select(columns: Set(FeatureColumn.fusion)) { !$0.golden && !$0.nsfw }
        var order = (0..<selection.count).filter { selection.vector(.dinoFusion, row: $0).first?.isFinite ?? false }
        order.sort { selection.rows[$0].id < selection.rows[$1].id }
        var histogram: [String: Int] = [:]
        for i in order { histogram[selection.rows[i].warpModel ?? "unknown", default: 0] += 1 }
        if histogram.count > 1 && !settings.allowMixedWarp {
            throw VeilGardeFailure.data("the store's warp column comes from \(histogram.count) warp models \(histogram); allow mixed warp rows to train anyway",
                                        hint: "rows without warp_model were scored by an older warp model (optimal_6); re-extract them or pass --allow-mixed-warp")
        }
        let emphasized = Set(settings.emphasize)
        var x: [Float] = [], y: [Float] = [], w: [Float] = [], ids: [String] = [], newGen: [Bool] = [], held: [Bool] = []
        x.reserveCapacity(order.count * FusionVector.count)
        for i in order {
            let row = selection.rows[i]
            for column in FeatureColumn.fusion { x.append(contentsOf: selection.vector(column, row: i)) }
            y.append(Float(row.label))
            let isNew = row.isGenerated && settings.newGeneratorShards.contains { selection.shards[i].hasPrefix($0) }
            var weight = isNew ? settings.newGeneratorWeight : (row.genFamily == "flux2-klein-4b" ? settings.fluxWeight : 1)
            if row.source == "preview_aug" { weight *= settings.previewWeight }
            if emphasized.contains(row.id) { weight *= settings.emphasizeWeight }
            w.append(Float(weight))
            ids.append(row.id)
            newGen.append(isNew)
            held.append(isNew && StableSplit.isHoldout(row.id, salt: "fusion-held:v1", fraction: settings.holdoutFraction))
        }
        return FusionDataset(ids: ids, data: BoostDataset(x: x, y: y, weight: w, features: FusionVector.count),
                             isNewGenerator: newGen, isHeldOut: held, warpModels: histogram)
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
    public var warpModels: [String: Int]
    public var seconds: Double
}

public enum FusionTrainer {
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
            params.trees = add
            params.eta = eta
            warm = parent
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
        if let parent {
            var same = 0
            for i in 0..<dataset.data.count {
                let row = dataset.data.row(i)
                if (parent.predict(row) > 0.5) == (model.predict(row) > 0.5) { same += 1 }
            }
            agreement = Double(same) / Double(max(1, dataset.data.count))
        }
        let report = FusionReport(rows: dataset.data.count, trainedOn: training.count, newGeneratorRows: dataset.isNewGenerator.filter { $0 }.count,
                                  heldOutRows: dataset.isHeldOut.filter { $0 }.count, heldOutRecallParent: parent.flatMap(recall),
                                  heldOutRecallCandidate: recall(model), agreementWithParent: agreement, trees: model.trees.count,
                                  inheritedTrees: boost.inheritedTrees, warpModels: dataset.warpModels, seconds: Date().timeIntervalSince(started))
        return (model, report)
    }
}
