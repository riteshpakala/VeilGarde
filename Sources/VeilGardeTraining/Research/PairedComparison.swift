//
//  PairedComparison.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: How the pruning study compares two scorings of the same held-out items: each one's AUC,
//        their difference, a bootstrap 95% interval on that difference, and how many calls the
//        change moves. One comparison is one row of a study.
//  PIN:  The bootstrap is Poisson(1): resample b weighs every item by an independent Poisson(1)
//        draw from SplitMix64(seed + b), which matches a multinomial resample in the limit and lets
//        one sorted order serve every resample (a weighted AUC is then one pass, ties counted
//        half). 1,000 resamples at seed 0 (ledger decision-68); the interval is the 2.5th and 97.5th
//        percentiles of variant − reference. Resamples run in parallel, each on its own stream, so
//        the interval does not depend on the thread count.
//

import Foundation
import VeilGardeCore

/// A scoring's ranks, sorted once, so each resample's weighted AUC is a single pass.
struct RankedScores {
    let order: [Int]
    let groupEnds: [Int]
    let positive: [Bool]

    init(_ scores: [Float], _ labels: [Float]) {
        order = scores.indices.sorted { scores[$0] < scores[$1] }
        var ends: [Int] = []
        var k = 0
        while k < order.count {
            var j = k + 1
            while j < order.count && scores[order[j]] == scores[order[k]] { j += 1 }
            ends.append(j)
            k = j
        }
        groupEnds = ends
        positive = labels.map { $0 > 0.5 }
    }

    /// The AUC with every item weighed by `weights` (nil: all 1); nil when a class weighs nothing.
    func auc(_ weights: [Double]?) -> Double? {
        var below = 0.0, total = 0.0, pos = 0.0, neg = 0.0
        var start = 0
        for end in groupEnds {
            var p = 0.0, n = 0.0
            for i in order[start..<end] {
                let w = weights?[i] ?? 1
                if positive[i] { p += w } else { n += w }
            }
            total += p * (below + 0.5 * n)
            below += n
            pos += p
            neg += n
            start = end
        }
        return pos > 0 && neg > 0 ? total / (pos * neg) : nil
    }
}

/// A Poisson(1) draw (Knuth's product of uniforms; the mean is two iterations).
func poissonOne(_ rng: inout SplitMix64) -> Double {
    let limit = exp(-1.0)
    var k = 0.0, product = rng.unit()
    while product > limit {
        k += 1
        product *= rng.unit()
    }
    return k
}

/// Two scorings of the same items, compared.
public struct PairedComparison: Codable, Sendable, Equatable {
    /// The reference scoring's AUC.
    public var reference: Double
    /// The variant's AUC.
    public var variant: Double
    /// variant − reference.
    public var delta: Double
    /// The 95% bootstrap interval of delta.
    public var low: Double
    public var high: Double
    public var items: Int
    /// Items whose call differs between the two scorings.
    public var changedCalls: Int
    public var changedShare: Double

    /// True when the interval holds zero: no measurable difference.
    public var spansZero: Bool { low <= 0 && high >= 0 }

    public static func measure(reference: [Float], variant: [Float], labels: [Float], resamples: Int, seed: UInt64,
                               call: (Float) -> String) -> PairedComparison {
        precondition(reference.count == labels.count && variant.count == labels.count, "a paired comparison needs one score per item on both sides")
        let a = RankedScores(reference, labels), b = RankedScores(variant, labels)
        let ra = a.auc(nil) ?? .nan, rb = b.auc(nil) ?? .nan
        var deltas = [Double](repeating: .nan, count: resamples)
        let n = labels.count
        deltas.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: resamples) { r in
                var rng = SplitMix64(seed: seed &+ UInt64(r))
                let w = (0..<n).map { _ in poissonOne(&rng) }
                if let x = a.auc(w), let y = b.auc(w) { out[r] = y - x }
            }
        }
        let sorted = deltas.filter { $0.isFinite }.sorted()
        func percentile(_ q: Double) -> Double {
            guard !sorted.isEmpty else { return .nan }
            return sorted[min(sorted.count - 1, max(0, Int((q * Double(sorted.count - 1)).rounded())))]
        }
        let changed = zip(reference, variant).filter { call($0.0) != call($0.1) }.count
        return PairedComparison(reference: ra, variant: rb, delta: rb - ra, low: percentile(0.025), high: percentile(0.975),
                                items: n, changedCalls: changed, changedShare: n > 0 ? Double(changed) / Double(n) : 0)
    }

    /// The same comparison with each side called by its own rule (two models, each with its own cuts).
    public static func measure(reference: [Float], variant: [Float], labels: [Float], resamples: Int, seed: UInt64,
                               referenceCall: (Float) -> String, variantCall: (Float) -> String) -> PairedComparison {
        var c = measure(reference: reference, variant: variant, labels: labels, resamples: resamples, seed: seed, call: { _ in "" })
        c.changedCalls = zip(reference, variant).filter { referenceCall($0.0) != variantCall($0.1) }.count
        c.changedShare = c.items > 0 ? Double(c.changedCalls) / Double(c.items) : 0
        return c
    }
}
