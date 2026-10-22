//
//  Verdict.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The three-state label every score becomes: "generated", "real", or "inconclusive" when
//        the score sits within the band of its threshold. One operating point for the detector,
//        0.5 ± 0.04; the screenshot member applies its head's own threshold with the same band.
//  PIN:  |score − threshold| < band is inconclusive (the band is open), and generated is strictly
//        greater than the threshold.
//

public struct DecisionRule: Sendable, Equatable, Codable {
    public var threshold: Float
    public var band: Float

    public init(threshold: Float, band: Float) {
        self.threshold = threshold
        self.band = band
    }

    /// The detector's operating point: the camera member at 0.5 ± 0.04.
    public static let camera = DecisionRule(threshold: 0.5, band: 0.04)

    public func label(_ score: Float) -> String {
        if abs(score - threshold) < band { return "inconclusive" }
        return score > threshold ? "generated" : "real"
    }
}
