//
//  GrayMappingTests.swift
//  VeilGardeAudioTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The grey mapping's fixed points: 0 dBFS is 255, −6.02 dB is 239, over full scale clamps,
//        under the floor is 0 and 0 is silence; it is monotone and inverts to within half a step.
//

import Foundation
import Testing
@testable import VeilGardeAudio

@Suite("The grey mapping")
struct GrayMappingTests {
    @Test("fixed points and clamps", arguments: [SpectrogramProfile.music, .speech])
    func fixedPoints(profile: SpectrogramProfile) {
        let reference = profile.magnitudeReference
        #expect(GrayMapping.level(magnitude: 0, profile: profile) == 0)
        #expect(GrayMapping.level(magnitude: reference, profile: profile) == 255)
        #expect(GrayMapping.level(magnitude: reference * 0.5, profile: profile) == 239)
        #expect(GrayMapping.level(magnitude: reference * pow(10, 3.0 / 20), profile: profile) == 255)
        #expect(GrayMapping.level(magnitude: reference * pow(10, -200.0 / 20), profile: profile) == 0)
        #expect(GrayMapping.level(magnitude: reference * pow(10, -96.0 / 20), profile: profile) == 0, "the floor itself reads 0")
        #expect(GrayMapping.level(magnitude: reference * pow(10, -95.0 / 20), profile: profile) == 3)
        #expect(GrayMapping.magnitude(level: 0, profile: profile) == 0 && GrayMapping.magnitude(level: 255, profile: profile) == reference)
        #expect(abs(GrayMapping.decibels(magnitude: reference, profile: profile)) < 1e-12 && GrayMapping.decibels(magnitude: 0, profile: profile) == -.infinity)
    }

    @Test("monotone, and inverts to within half a step")
    func monotone() {
        let profile = SpectrogramProfile.music
        var last: UInt8 = 0
        for i in 0..<10_000 {
            let dB = -100 + 105 * Double(i) / 9_999
            let m = profile.magnitudeReference * pow(10, dB / 20)
            let level = GrayMapping.level(magnitude: m, profile: profile)
            #expect(level >= last, "level fell at \(dB) dB")
            last = level
            if level > 0 && level < 255 {
                let back = GrayMapping.decibels(magnitude: GrayMapping.magnitude(level: level, profile: profile), profile: profile)
                #expect(abs(back - dB) <= 96.0 / 255 / 2 + 1e-9, "\(dB) dB came back as \(back)")
            }
        }
    }
}
