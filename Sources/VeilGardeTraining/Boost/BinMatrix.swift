//
//  BinMatrix.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The quantized training matrix: each feature's values cut into at most 256 bins, stored
//        column-major as one byte per value, so a tree level is one pass of byte-indexed histogram
//        adds instead of a sort.
//  PIN:  A feature with at most 256 distinct values cuts at its own values (so a split threshold is
//        a value the data holds, as XGBoost's exact sketch places it); otherwise at 255 quantiles
//        of a seeded sample of at most one million rows. bin(v) = the number of cuts ≤ v, so "bins
//        ≤ b go left" is exactly "v < cuts[b]", the comparison the evaluator makes. NaN takes the
//        bin past the last cut and so always goes right, as NaN < cut is false at inference.
//

import Foundation

public struct BinMatrix: Sendable {
    public let rows: Int
    public let features: Int
    /// Per feature, its ascending cut values.
    public let cuts: [[Float]]
    /// Column-major [features][rows].
    public let bins: [UInt8]

    public func bin(_ feature: Int, _ row: Int) -> UInt8 { bins[feature * rows + row] }

    public static func cuts(for data: BoostDataset, maxBin: Int, seed: UInt64) -> [[Float]] {
        let n = data.count, f = data.features
        let sampleCap = 1_000_000
        var sample: [Int] = Array(0..<n)
        if n > sampleCap {
            var rng = SplitMix64(seed: seed ^ 0xC07)
            sample = Array(rng.permutation(n).prefix(sampleCap)).sorted()
        }
        return (0..<f).map { j -> [Float] in
            var values = sample.map { data.x[$0 * f + j] }.filter { $0.isFinite }
            values.sort()
            guard let first = values.first else { return [] }
            var unique: [Float] = [first]
            for v in values.dropFirst() where v != unique.last! { unique.append(v) }
            if unique.count <= maxBin { return Array(unique.dropFirst()) }
            var out: [Float] = []
            for k in 1..<maxBin {
                let v = values[min(values.count - 1, Int(Double(k) * Double(values.count) / Double(maxBin)))]
                if v > first, out.last.map({ v > $0 }) ?? true { out.append(v) }
            }
            return out
        }
    }

    public init(_ data: BoostDataset, cuts: [[Float]]) {
        self.rows = data.count
        self.features = data.features
        self.cuts = cuts
        var bins = [UInt8](repeating: 0, count: data.count * data.features)
        let n = data.count, f = data.features
        bins.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: f) { j in
                let c = cuts[j]
                for i in 0..<n {
                    let v = data.x[i * f + j]
                    var b: Int
                    if !v.isFinite { b = c.count } else {
                        var lo = 0, hi = c.count            // upper bound: the number of cuts ≤ v
                        while lo < hi { let mid = (lo + hi) / 2; if c[mid] <= v { lo = mid + 1 } else { hi = mid } }
                        b = lo
                    }
                    out[j * n + i] = UInt8(min(b, 255))
                }
            }
        }
        self.bins = bins
    }
}
