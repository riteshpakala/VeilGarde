//
//  Metrics.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The metrics every trainer reports: ROC AUC (ties averaged), log loss, and the rates at an
//        operating point (real false positives, generated recall, the inconclusive share).
//

import Foundation

public enum Metrics {
    /// ROC AUC by the rank statistic, ties given their average rank; NaN when a class is absent.
    public static func auc(_ scores: [Float], _ labels: [Float], weights: [Float]? = nil) -> Double {
        let n = scores.count
        guard n > 0 else { return .nan }
        let order = (0..<n).sorted { scores[$0] < scores[$1] }
        var ranks = [Double](repeating: 0, count: n)
        var i = 0
        while i < n {
            var j = i
            while j + 1 < n && scores[order[j + 1]] == scores[order[i]] { j += 1 }
            let average = Double(i + j) / 2 + 1
            for k in i...j { ranks[order[k]] = average }
            i = j + 1
        }
        if let weights {
            // Weighted AUC by pair counting over the sorted order.
            var positiveWeight = 0.0, negativeWeight = 0.0, area = 0.0, cumulativeNegative = 0.0
            var k = 0
            while k < n {
                var m = k
                var tiePositive = 0.0, tieNegative = 0.0
                while m < n && scores[order[m]] == scores[order[k]] {
                    let w = Double(weights[order[m]])
                    if labels[order[m]] > 0.5 { tiePositive += w } else { tieNegative += w }
                    m += 1
                }
                area += tiePositive * (cumulativeNegative + tieNegative / 2)
                cumulativeNegative += tieNegative
                positiveWeight += tiePositive
                negativeWeight += tieNegative
                k = m
            }
            return positiveWeight > 0 && negativeWeight > 0 ? area / (positiveWeight * negativeWeight) : .nan
        }
        var positives = 0.0, rankSum = 0.0
        for k in 0..<n where labels[k] > 0.5 { positives += 1; rankSum += ranks[k] }
        let negatives = Double(n) - positives
        guard positives > 0, negatives > 0 else { return .nan }
        return (rankSum - positives * (positives + 1) / 2) / (positives * negatives)
    }

    public static func logloss(_ p: [Float], _ labels: [Float]) -> Double {
        guard !p.isEmpty else { return .nan }
        var total = 0.0
        for (pi, yi) in zip(p, labels) {
            let q = min(max(Double(pi), 1e-15), 1 - 1e-15)
            total -= yi > 0.5 ? log(q) : log(1 - q)
        }
        return total / Double(p.count)
    }

    public struct OperatingPoint: Codable, Sendable, Equatable {
        public var threshold: Double
        public var band: Double
        public var accuracy: Double
        public var realFalsePositiveRate: Double
        public var generatedRecall: Double
        public var inconclusiveRate: Double
    }

    /// The rates of a three-state rule: inconclusive within the band, generated strictly above.
    public static func operatingPoint(_ p: [Float], _ labels: [Float], threshold: Double, band: Double) -> OperatingPoint {
        var correct = 0, decided = 0, realFP = 0, reals = 0, genTP = 0, gens = 0, inconclusive = 0
        for (pi, yi) in zip(p, labels) {
            let v = Double(pi)
            let isGen = yi > 0.5
            if isGen { gens += 1 } else { reals += 1 }
            if abs(v - threshold) < band { inconclusive += 1; continue }
            decided += 1
            let saysGen = v > threshold
            if saysGen == isGen { correct += 1 }
            if saysGen && !isGen { realFP += 1 }
            if saysGen && isGen { genTP += 1 }
        }
        return OperatingPoint(threshold: threshold, band: band, accuracy: decided > 0 ? Double(correct) / Double(decided) : .nan,
                              realFalsePositiveRate: reals > 0 ? Double(realFP) / Double(reals) : .nan,
                              generatedRecall: gens > 0 ? Double(genTP) / Double(gens) : .nan,
                              inconclusiveRate: p.isEmpty ? .nan : Double(inconclusive) / Double(p.count))
    }
}
