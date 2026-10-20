//
//  BoostParams.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The gradient-boosted trees' hyperparameters, with XGBoost's names and defaults, and the
//        dataset a booster trains on.
//  PIN:  XGBoost defaults: η 0.3, depth 6, λ 1, γ 0, min_child_weight 1, subsample and
//        colsample_bytree 1, scale_pos_weight 1, 256 bins (`hist`). base_score defaults to the
//        weighted label mean (XGBoost 2.x estimates its intercept; the trees absorb the difference).
//

public struct BoostParams: Codable, Sendable, Equatable {
    public var trees = 200
    public var maxDepth = 6
    public var eta: Double = 0.3
    public var lambda: Double = 1
    public var gamma: Double = 0
    public var minChildWeight: Double = 1
    public var subsample: Double = 1
    public var colsampleByTree: Double = 1
    public var scalePosWeight: Double = 1
    public var baseScore: Double? = nil
    public var maxBin = 256
    public var earlyStoppingRounds: Int? = nil
    public var metric: BoostMetric = .auc
    public var seed: UInt64 = 0

    public init(trees: Int = 200, maxDepth: Int = 6, eta: Double = 0.3, lambda: Double = 1, gamma: Double = 0, minChildWeight: Double = 1,
                subsample: Double = 1, colsampleByTree: Double = 1, scalePosWeight: Double = 1, baseScore: Double? = nil, maxBin: Int = 256,
                earlyStoppingRounds: Int? = nil, metric: BoostMetric = .auc, seed: UInt64 = 0) {
        self.trees = trees
        self.maxDepth = maxDepth
        self.eta = eta
        self.lambda = lambda
        self.gamma = gamma
        self.minChildWeight = minChildWeight
        self.subsample = subsample
        self.colsampleByTree = colsampleByTree
        self.scalePosWeight = scalePosWeight
        self.baseScore = baseScore
        self.maxBin = maxBin
        self.earlyStoppingRounds = earlyStoppingRounds
        self.metric = metric
        self.seed = seed
    }
}

public enum BoostMetric: String, Codable, Sendable {
    case auc, logloss
}

/// A row-major n × f float matrix, its 0/1 labels and optional weights.
public struct BoostDataset: Sendable {
    public var x: [Float]
    public var y: [Float]
    public var weight: [Float]?
    public let features: Int

    public init(x: [Float], y: [Float], weight: [Float]? = nil, features: Int) {
        precondition(x.count == y.count * features, "x holds \(x.count) values for \(y.count) × \(features)")
        self.x = x
        self.y = y
        self.weight = weight
        self.features = features
    }

    public var count: Int { y.count }

    public func row(_ i: Int) -> [Float] { Array(x[(i * features)..<((i + 1) * features)]) }
}
