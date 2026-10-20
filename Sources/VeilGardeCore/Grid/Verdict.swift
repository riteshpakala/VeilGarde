//
//  Verdict.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The three-state label every score becomes: "generated", "real", or "inconclusive" when
//        the score sits within the band of its threshold. One rule, many operating points: the
//        warp-only weighted score at 0.56 ± 0.04, the fusion base at 0.5 ± 0.04, the sensor lane
//        at its calibrated threshold (SensorCalibrationContract.prediction).
//  PIN:  |score − threshold| < band is inconclusive (the band is open), and generated is strictly
//        greater than the threshold. The 0.56 and 0.5 operating points are an intentional duality
//        (Garde's 2026-07-16 audit note): do not unify them.
//

public struct DecisionRule: Sendable, Equatable, Codable {
    public var threshold: Float
    public var band: Float

    public init(threshold: Float, band: Float) {
        self.threshold = threshold
        self.band = band
    }

    /// The warp-only weighted verdict's operating point (v2.4 recalibration).
    public static let warpWeighted = DecisionRule(threshold: 0.56, band: 0.04)
    /// The fusion base's and the stack's operating point.
    public static let fusion = DecisionRule(threshold: 0.5, band: 0.04)

    public func label(_ score: Float) -> String {
        if abs(score - threshold) < band { return "inconclusive" }
        return score > threshold ? "generated" : "real"
    }
}

/// How the weighted verdict's hotspot blend treats confident patches. `.asymmetric` (legacy) lets
/// only patches above the threshold pull the score up, which inflated real-image scores by +0.03
/// and flipped about a third of real verdicts (Understanding.md F2); `.symmetric` blends toward
/// every confident patch, generated or real.
public enum HotspotMode: String, Sendable, Codable, CaseIterable {
    case off, asymmetric, symmetric
}

/// The hotspot blend: when any patch is confident, score = (1 − blend)·score + blend·mean(confident).
public struct HotspotRule: Sendable, Equatable, Codable {
    public var mode: HotspotMode
    public var blend: Float
    public var threshold: Float

    public init(mode: HotspotMode = .symmetric, blend: Float = 0.35, threshold: Float = 0.60) {
        self.mode = mode
        self.blend = blend
        self.threshold = threshold
    }
}
