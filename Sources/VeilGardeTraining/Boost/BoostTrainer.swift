//
//  BoostTrainer.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Trains a binary-logistic gradient-boosted ensemble from a feature matrix, from scratch or
//        by appending trees to an existing booster (a warm start), and returns it as a GBDTModel
//        that writes the XGBoost JSON Frigate's evaluator reads.
//  PIN:  XGBoost 3.2's gradients in Float: p = 1/(1+e^−m), g = (p − y)·w, h = max(p(1 − p), 1e−16)·w,
//        w = the row weight × scale_pos_weight on positives. Margins are kept in Float, start at
//        logit(base_score) (or the warm-start model's margin), and add each tree's leaf. The
//        default base_score is XGBoost 3.2's: the weighted label mean when scale_pos_weight is 1,
//        one Newton step from margin 0 otherwise (measured against xgboost 3.2.0 on 2026-10-19).
//        Row subsample and column sample per tree draw from SplitMix64(seed ^ tree index), so they
//        differ from XGBoost's generator but repeat exactly here. A column mask draws the column
//        sample from its own columns, ⌊colsample · mask⌋ of them by the same permutation over the
//        mask's count, and the model keeps the data's width: a masked fit grows, node for node,
//        the trees a refit on only those columns would grow. Early stopping keeps the first
//        best round and truncates the model to it. A warm start never touches the inherited trees:
//        they keep their JSON text and encode back byte for byte.
//

import Foundation
import VeilGardeCore

public struct BoostRound: Codable, Sendable, Equatable {
    /// The tree's index in the model (inherited trees count).
    public var tree: Int
    public var validation: Double?
    public var seconds: Double
}

public struct BoostResult: Sendable {
    public var model: GBDTModel
    public var rounds: [BoostRound]
    /// The model's tree count at the best validation round, when early stopping ran.
    public var bestTreeCount: Int?
    public var inheritedTrees: Int
    public var cuts: [[Float]]
}

public enum BoostTrainer {
    /// XGBoost 3.2's intercept estimate for binary:logistic.
    public static func baseScore(_ data: BoostDataset, scalePosWeight: Double) -> Double {
        var sw = 0.0, swy = 0.0, sg = 0.0, sh = 0.0
        for i in 0..<data.count {
            let y = Double(data.y[i])
            var w = Double(data.weight?[i] ?? 1)
            if y == 1 { w *= scalePosWeight }
            sw += w; swy += w * y
            sg += (0.5 - y) * w; sh += 0.25 * w
        }
        guard sw > 0 else { return 0.5 }
        if scalePosWeight == 1 { return swy / sw }
        return 1 / (1 + exp(sg / sh))
    }

    public static func train(_ train: BoostDataset, validation: BoostDataset? = nil, params: BoostParams,
                             warmStart: GBDTModel? = nil, featureNames: [String] = [],
                             progress: (BoostRound) -> Void = { _ in }) -> BoostResult {
        let n = train.count, f = train.features
        let pool = params.allowedColumns ?? Array(0..<f)
        precondition(!pool.isEmpty && pool.allSatisfy { (0..<f).contains($0) } && zip(pool, pool.dropFirst()).allSatisfy { $0 < $1 },
                     "allowedColumns must be distinct ascending columns of the \(f)-column data, not \(pool)")
        let cuts = BinMatrix.cuts(for: train, maxBin: params.maxBin, seed: params.seed)
        let matrix = BinMatrix(train, cuts: cuts)

        var model: GBDTModel
        var margins = [Float](repeating: 0, count: n)
        if let warmStart {
            precondition(warmStart.featureCount == f, "the warm-start model reads \(warmStart.featureCount) features, the data has \(f)")
            model = warmStart
            margins.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: chunks(n)) { c in
                    for i in chunkRange(c, n) { out[i] = warmStart.margin(train.row(i)) }
                }
            }
        } else {
            let base = params.baseScore ?? baseScore(train, scalePosWeight: params.scalePosWeight)
            model = GBDTModel(trees: [], baseScoreProbability: Float(base), featureCount: f,
                              scalePosWeight: Float(params.scalePosWeight), featureNames: featureNames,
                              featureTypes: featureNames.isEmpty ? [] : Array(repeating: "float", count: featureNames.count))
            let m0 = model.baseMargin
            for i in 0..<n { margins[i] = m0 }
        }
        let inherited = model.trees.count

        let validationRows: [[Float]] = validation.map { v in (0..<v.count).map { v.row($0) } } ?? []
        var validationMargins: [Float] = validationRows.map { model.margin($0) }

        let spw = Float(params.scalePosWeight)
        var g = [Float](repeating: 0, count: n), h = [Float](repeating: 0, count: n)
        var rounds: [BoostRound] = []
        var best: (score: Double, trees: Int)? = nil
        var sinceBest = 0

        for round in 0..<params.trees {
            let started = Date()
            // Gradients at the current margins.
            g.withUnsafeMutableBufferPointer { gp in
                h.withUnsafeMutableBufferPointer { hp in
                    DispatchQueue.concurrentPerform(iterations: chunks(n)) { c in
                        for i in chunkRange(c, n) {
                            let p: Float = 1 / (1 + Foundation.exp(-margins[i]))
                            let y = train.y[i]
                            var w = train.weight?[i] ?? 1
                            if y == 1 { w *= spw }
                            gp[i] = (p - y) * w
                            hp[i] = max(p * (1 - p), 1e-16) * w
                        }
                    }
                }
            }
            // This tree's rows and columns.
            var rng = SplitMix64(seed: params.seed ^ (UInt64(round) &* 0x9E37_79B9_7F4A_7C15 &+ 0x5EED))
            var rows: [Int32]
            if params.subsample < 1 {
                rows = []
                rows.reserveCapacity(Int(Double(n) * params.subsample) + 16)
                for i in 0..<n where rng.unit() < params.subsample { rows.append(Int32(i)) }
            } else {
                rows = (0..<n).map { Int32($0) }
            }
            var features = pool
            if params.colsampleByTree < 1 {
                let k = max(1, Int(params.colsampleByTree * Double(pool.count)))
                features = rng.permutation(pool.count).prefix(k).map { pool[$0] }.sorted()
            }

            let grower = TreeGrower(matrix: matrix, params: params, features: features)
            let grown = grower.grow(id: model.trees.count, rows: rows, gradients: g, hessians: h)
            model.trees.append(grown.tree)

            // Every training row (sampled or not) takes its leaf, walked on the bins.
            let tree = grown.tree, splitBins = grown.splitBins
            margins.withUnsafeMutableBufferPointer { out in
                matrix.bins.withUnsafeBufferPointer { bins in
                    DispatchQueue.concurrentPerform(iterations: chunks(n)) { c in
                        for i in chunkRange(c, n) {
                            var node = 0
                            while tree.leftChildren[node] != -1 {
                                let column = Int(tree.splitIndices[node])
                                node = Int32(bins[column * n + i]) <= splitBins[node] ? Int(tree.leftChildren[node]) : Int(tree.rightChildren[node])
                            }
                            out[i] += tree.baseWeights[node]
                        }
                    }
                }
            }

            var score: Double? = nil
            if let validation {
                for i in 0..<validationRows.count { validationMargins[i] += tree.leafValue(for: validationRows[i]) }
                let p = validationMargins.map { 1 / (1 + Foundation.exp(-$0)) }
                score = params.metric == .auc ? Metrics.auc(p, validation.y, weights: validation.weight)
                                              : Metrics.logloss(p, validation.y)
            }
            let entry = BoostRound(tree: model.trees.count - 1, validation: score, seconds: Date().timeIntervalSince(started))
            rounds.append(entry)
            progress(entry)

            if let score, let patience = params.earlyStoppingRounds {
                let better: Bool
                if let b = best { better = params.metric == .auc ? score > b.score : score < b.score } else { better = true }
                if better { best = (score, model.trees.count); sinceBest = 0 } else { sinceBest += 1 }
                if sinceBest >= patience { break }
            }
        }

        if let best, params.earlyStoppingRounds != nil, best.trees < model.trees.count {
            model.trees.removeSubrange(best.trees...)
        }
        return BoostResult(model: model, rounds: rounds, bestTreeCount: params.earlyStoppingRounds != nil ? best?.trees : nil,
                           inheritedTrees: inherited, cuts: cuts)
    }

    // MARK: Chunking

    static let chunkSize = 16_384
    static func chunks(_ n: Int) -> Int { max(1, (n + chunkSize - 1) / chunkSize) }
    static func chunkRange(_ c: Int, _ n: Int) -> Range<Int> { (c * chunkSize)..<min(n, (c + 1) * chunkSize) }
}
