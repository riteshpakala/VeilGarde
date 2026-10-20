//
//  StandardScaler.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: sklearn's StandardScaler: each column's mean and population standard deviation over the
//        training rows, and the transform (x − mean) / scale that every linear head applies.
//  PIN:  ddof 0, accumulated in Double; a zero spread scales by 1 (sklearn's
//        `_handle_zeros_in_scale`), so a constant column passes through centred.
//

public struct StandardScaler: Sendable, Equatable {
    public let mean: [Double]
    public let scale: [Double]

    public init(mean: [Double], scale: [Double]) {
        self.mean = mean
        self.scale = scale
    }

    /// Fits on the rows `rows` of a row-major n × d matrix.
    public static func fit(_ x: [Float], d: Int, rows: [Int]) -> StandardScaler {
        var mean = [Double](repeating: 0, count: d)
        for r in rows { let base = r * d; for j in 0..<d { mean[j] += Double(x[base + j]) } }
        let n = Double(max(1, rows.count))
        for j in 0..<d { mean[j] /= n }
        var variance = [Double](repeating: 0, count: d)
        for r in rows { let base = r * d; for j in 0..<d { let v = Double(x[base + j]) - mean[j]; variance[j] += v * v } }
        let scale = variance.map { v -> Double in
            let s = (v / n).squareRoot()
            return s < 10 * Double.ulpOfOne ? 1 : s
        }
        return StandardScaler(mean: mean, scale: scale)
    }

    /// The scaled rows as Double, row-major [rows.count × d].
    public func transform(_ x: [Float], d: Int, rows: [Int]) -> [Double] {
        var out = [Double](repeating: 0, count: rows.count * d)
        for (k, r) in rows.enumerated() {
            let base = r * d, o = k * d
            for j in 0..<d { out[o + j] = (Double(x[base + j]) - mean[j]) / scale[j] }
        }
        return out
    }
}
