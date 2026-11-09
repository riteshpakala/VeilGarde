//
//  LinkTests.swift
//  VeilGardeAudioTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The module links and re-exports the watermark, the Lens and Core: one import reaches the
//        version, the match defaults and a clip.
//

import Testing
import VeilGardeAudio

@Suite("VeilGardeAudio links")
struct LinkTests {
    @Test("one import reaches Core's version, the watermark's defaults and a clip")
    func reExports() {
        #expect(!VeilGardeVersion.string.isEmpty)
        #expect(MatchOptions.default.threshold == 0.75 && MatchOptions.default.minimumBits == 256)
        #expect(AudioClip(sampleRate: 16_000, mono: [0, 0.5]).frames == 2)
    }
}
