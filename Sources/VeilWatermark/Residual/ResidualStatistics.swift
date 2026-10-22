//
//  ResidualStatistics.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The warp residual summarised as numbers: each of the 19 tile features' mean, then its
//        spread, over every tile of the image at the 512-px cap, 38 numbers. No detector reads
//        them today; a stack member that does would take them as a shared signal, while the
//        residual's code stays here, in the watermark.
//  PIN:  Mean and population standard deviation, accumulated in Double over every tile of the
//        padded grid, as the research's pre-test computed them from its tiles (2026-10-21). The
//        order is `names`: each feature's mean, then each feature's spread.
//

import CoreGraphics
import Foundation

public enum ResidualStatistics {
    /// The 19 tile features, in the tile extractor's order.
    public static let features = ["FR", "LV", "CV", "CM", "CC", "CR", "SH", "SV", "SH_S", "SV_S", "xcorr_RG", "cfa_G",
                                  "xcorr_BG", "xcorr_RB", "cfa_R", "cfa_B", "noise_ratio", "diag_axial", "nyq_R"]

    /// The 38 numbers' names: each feature's mean, then each feature's spread.
    public static var names: [String] { features.map { "\($0)_mean" } + features.map { "\($0)_std" } }

    public static let count = 2 * features.count

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
