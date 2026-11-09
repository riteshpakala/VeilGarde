//
//  GrayMapping.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A magnitude to one of 256 grey levels and back: the mapping that makes a sound a picture
//        the warp round trip can read.
//  PIN:  dB = 20·log10(|X| / (N/4)), so a full-scale sine's peak bin reads 0 dBFS; level =
//        round(255 · (dB + 96) / 96) to nearest, away from zero on a tie, clamped to 255, so one
//        level is 0.376 dB; a magnitude of zero, or one under the floor plus half a step, is level
//        0, and level 0 dequantizes to zero. Absolute dBFS, never the clip's own peak: a cut's
//        pixels must equal its source's, and an additive constant survives the warps only when it
//        is a whole number of levels (−6.02 dB is 15.99 of them). 0 dBFS → 255, −6.02 dB → 239.
//

import Foundation

public enum GrayMapping {
    public static var span: Double { SpectrogramProfile.ceilingDB - SpectrogramProfile.floorDB }

    /// `magnitude` in dBFS under the profile's reference; −infinity at zero.
    public static func decibels(magnitude: Double, profile: SpectrogramProfile) -> Double {
        magnitude > 0 ? 20 * log10(magnitude / profile.magnitudeReference) : -.infinity
    }

    public static func level(magnitude: Double, profile: SpectrogramProfile) -> UInt8 {
        guard magnitude > 0 else { return 0 }
        let x = (decibels(magnitude: magnitude, profile: profile) - SpectrogramProfile.floorDB) / span * Double(SpectrogramProfile.levels)
        if x < 0.5 { return 0 }
        return UInt8(min(Double(SpectrogramProfile.levels), x.rounded(.toNearestOrAwayFromZero)))
    }

    /// The magnitude a level stands for: the centre of its step; zero for level 0.
    public static func magnitude(level: UInt8, profile: SpectrogramProfile) -> Double {
        guard level > 0 else { return 0 }
        let dB = SpectrogramProfile.floorDB + Double(level) / Double(SpectrogramProfile.levels) * span
        return profile.magnitudeReference * pow(10, dB / 20)
    }
}
