//
//  WarpTrainer.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The core thesis as a trainer: the warp tile model, a gradient-boosted classifier on the
//        19 features of every 32-px tile, trained on the tile cache's train partition and judged
//        on its validation and test partitions both per tile and per image (the weighted score the
//        detector reports, and the majority fraction the sensor lane calibrates).
//  PIN:  Two shapes. `deployed` is optimal_8's recorded settings (its pickle's get_params:
//        200 trees, depth 8, η 0.1, subsample 0.8, colsample_bytree 0.8, seed 0, scale_pos_weight
//        1). `v18` is retrain_optimal.py's (400 trees, depth 4, η 0.03, subsample 0.8,
//        scale_pos_weight 0.98, early stopping 30 on validation AUC). Per-image scores rebuild the
//        detector's arithmetic from the cached tiles: the weight map from the tile probabilities
//        and texture weights, the weighted verdict with the default hotspot rule, and the strict
//        `> 0.5` majority count. The trainer writes nothing; the engine does.
//

import Foundation
import VeilGardeCore
import VeilGardeLens

public enum WarpShape: String, Codable, Sendable, CaseIterable {
    case deployed
    case v18

    public var params: BoostParams {
        switch self {
        case .deployed:
            return BoostParams(trees: 200, maxDepth: 8, eta: 0.1, subsample: 0.8, colsampleByTree: 0.8, metric: .auc, seed: 0)
        case .v18:
            return BoostParams(trees: 400, maxDepth: 4, eta: 0.03, subsample: 0.8, scalePosWeight: 0.98, earlyStoppingRounds: 30, metric: .auc, seed: 0)
        }
    }
}

public struct PartitionMetrics: Codable, Sendable, Equatable {
    public var images: Int
    public var tiles: Int
    public var tileAUC: Double
    public var imageWeightedAUC: Double
    public var imageMajorityAUC: Double
    /// The weighted score's three-state call at the detector's 0.56 ± 0.04.
    public var weighted: Metrics.OperatingPoint
}

public struct WarpEvaluation: Codable, Sendable, Equatable {
    public var validation: PartitionMetrics?
    public var test: PartitionMetrics?
}

public enum WarpTrainer {
    /// The detector's weighted-score rule.
    public static let decision = DecisionRule.warpWeighted

    public struct Result: Sendable {
        public var model: GBDTModel
        public var boost: BoostResult
        public var evaluation: WarpEvaluation
        public var trainTiles: Int
        public var trainImages: Int
    }

    public static func train(shards: [TileShard], params: BoostParams, include: (TileImage) -> Bool = { _ in true },
                             note: (String) -> Void = { _ in }) -> Result {
        let train = TileSet.gather(shards, partitions: [.train], include: include)
        let validation = TileSet.gather(shards, partitions: [.val], include: include)
        let test = TileSet.gather(shards, partitions: [.test], include: include)
        note("warp: \(train.images.count) train images (\(train.tileCount) tiles), \(validation.images.count) validation, \(test.images.count) test")
        let boost = BoostTrainer.train(train.data, validation: validation.tileCount > 0 ? validation.data : nil, params: params,
                                       featureNames: WarpFeatures.names) { round in
            if (round.tree + 1) % 20 == 0 || round.tree + 1 == params.trees {
                note("warp: tree \(round.tree + 1)" + (round.validation.map { String(format: " validation tile AUC %.4f", $0) } ?? "")
                     + String(format: " (%.2fs)", round.seconds))
            }
        }
        let evaluation = evaluate(boost.model, validation: validation, test: test)
        return Result(model: boost.model, boost: boost, evaluation: evaluation, trainTiles: train.tileCount, trainImages: train.images.count)
    }

    public static func evaluate(_ model: TileScorer, validation: TileSet, test: TileSet) -> WarpEvaluation {
        WarpEvaluation(validation: validation.images.isEmpty ? nil : metrics(model, validation),
                       test: test.images.isEmpty ? nil : metrics(model, test))
    }

    public struct ImageScores: Sendable {
        public var labels: [Float]
        public var weighted: [Float]
        public var majority: [Float]
        public var tileProbabilities: [Float]
    }

    /// Every image's weighted score and majority fraction under `model`, from its cached tiles.
    public static func imageScores(_ model: TileScorer, _ set: TileSet) -> ImageScores {
        let f = set.data.features
        let rows = (0..<set.tileCount).map { Array(set.data.x[($0 * f)..<(($0 + 1) * f)]) }
        var p = [Float](repeating: 0, count: rows.count)
        let chunk = 4096
        p.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: (rows.count + chunk - 1) / chunk) { c in
                let range = (c * chunk)..<min(rows.count, (c + 1) * chunk)
                let scored = model.scoreBatch(Array(rows[range]))
                for (k, v) in scored.enumerated() { out[range.lowerBound + k] = v }
            }
        }
        let parameters = WarpParameters()
        var weighted: [Float] = [], majority: [Float] = [], labels: [Float] = []
        for image in set.images {
            let tiles = Array(p[image.range]), tex = Array(set.texture[image.range])
            let grid = (0..<image.rows).map { Array(tiles[($0 * image.cols)..<(($0 + 1) * image.cols)]) }
            let texGrid = (0..<image.rows).map { Array(tex[($0 * image.cols)..<(($0 + 1) * image.cols)]) }
            let map = WeightMap.build(patchGrid: grid, texWeights: texGrid, parameters: parameters.weightMap)
            weighted.append(WeightedVerdict.score(patchGrid: grid, weightMap: map, hotspot: parameters.hotspot))
            majority.append(Float(tiles.filter { $0 > 0.5 }.count) / Float(max(1, tiles.count)))
            labels.append(Float(image.label))
        }
        return ImageScores(labels: labels, weighted: weighted, majority: majority, tileProbabilities: p)
    }

    static func metrics(_ model: TileScorer, _ set: TileSet) -> PartitionMetrics {
        let s = imageScores(model, set)
        return PartitionMetrics(images: set.images.count, tiles: set.tileCount,
                                tileAUC: Metrics.auc(s.tileProbabilities, set.data.y),
                                imageWeightedAUC: Metrics.auc(s.weighted, s.labels),
                                imageMajorityAUC: Metrics.auc(s.majority, s.labels),
                                weighted: Metrics.operatingPoint(s.weighted, s.labels, threshold: Double(decision.threshold), band: Double(decision.band)))
    }
}
