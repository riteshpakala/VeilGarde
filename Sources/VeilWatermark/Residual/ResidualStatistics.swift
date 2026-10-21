//
//  ResidualStatistics.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The warp residual summarised for detection: each of the 19 tile features' mean, then
//        its spread, over every tile of the image at the 512-px cap, 38 numbers. The fusion head
//        reads them as the store's `residual` column; the residual's code stays here, in the
//        watermark, and detection reads only these numbers.
//  PIN:  Mean and population standard deviation, accumulated in Double over every tile of the
//        padded grid, as the research's pre-test computed them from its tiles (2026-10-21). The
//        order is FeatureColumn.residualNames.
//

import CoreGraphics
import Foundation

public enum ResidualStatistics {
    public static let count = FeatureColumn.residual.width

    /// The 38 numbers of one image.
    public static func measure(_ cg: CGImage) throws -> [Float] {
        summarize(TileFeatures.measure(try TilePlane(cg)))
    }

    /// Each feature's mean, then each feature's spread, over the tiles.
    public static func summarize(_ rows: TileFeatureRows) -> [Float] {
        let f = TileFeatureRows.featureCount, n = rows.count
        var sum = [Double](repeating: 0, count: f), squares = [Double](repeating: 0, count: f)
        for t in 0..<n {
            for k in 0..<f {
                let v = Double(rows.values[t * f + k])
                sum[k] += v
                squares[k] += v * v
            }
        }
        let N = Double(max(1, n))
        let mean = sum.map { $0 / N }
        let spread = (0..<f).map { max(0, squares[$0] / N - mean[$0] * mean[$0]).squareRoot() }
        return (mean + spread).map(Float.init)
    }
}
