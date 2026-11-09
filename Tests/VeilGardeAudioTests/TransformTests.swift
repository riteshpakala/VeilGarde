//
//  TransformTests.swift
//  VeilGardeAudioTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What the acceptance does to a clip, on the CPU: a cut's bounds, the gain, the 16-bit grid,
//        the noise's ratio, a speed change's length; and the synthetic clips: seeded, peak-normalised,
//        a tone at its frequency, silence silent.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeAudio

@Suite("Transforms and synthetic clips")
struct TransformTests {
    static let clip = SyntheticClips.musicLike(seed: 1, seconds: 12, sampleRate: 44_100)

    @Test("a cut is clamped to the clip")
    func cut() {
        let c = Self.clip
        #expect(AudioTransforms.cut(c, startSample: 100, length: 50).channels[0] == Array(c.channels[0][100..<150]))
        #expect(AudioTransforms.cut(c, startSample: c.frames - 10, length: 50).frames == 10)
        #expect(AudioTransforms.cut(c, startSample: -5, length: 3).frames == 3 && AudioTransforms.cut(c, startSample: c.frames + 9, length: 3).frames == 0)
    }

    @Test("−6.02 dB halves every sample; 16 bits land on the grid; the noise sits at its ratio")
    func levels() {
        let c = Self.clip
        let half = AudioTransforms.gained(c, dB: 20 * log10(0.5))
        #expect(zip(half.channels[0], c.channels[0]).allSatisfy { abs($0 - $1 * 0.5) <= ($1 * 0.5).ulp })
        let q = AudioTransforms.requantized16Bit(c)
        #expect(q.channels[0].allSatisfy { abs(Double($0) * 32_767 - (Double($0) * 32_767).rounded()) < 1e-3 })
        let noisy = AudioTransforms.withWhiteNoise(c, snrDB: 30, seed: 9)
        var signal = 0.0, noise = 0.0
        for (y, x) in zip(noisy.channels[0], c.channels[0]) { signal += Double(x) * Double(x); noise += Double(y - x) * Double(y - x) }
        #expect(abs(10 * log10(signal / noise) - 30) < 0.5)
        #expect(AudioTransforms.withWhiteNoise(c, snrDB: 30, seed: 9) == noisy)
    }

    @Test("a speed change scales the duration by its factor")
    func speed() throws {
        let c = AudioTransforms.cut(Self.clip, startSample: 0, length: 220_500)
        for factor in [0.9, 0.75] {
            let s = try AudioConverting.speedChanged(c, by: factor)
            #expect(abs(s.frames - Int((Double(c.frames) * factor).rounded())) <= 1 && s.sampleRate == c.sampleRate)
        }
    }

    @Test("synthetic clips: seeded, peak 0.5, a tone at its frequency, silence silent")
    func synthetic() {
        let a = SyntheticClips.musicLike(seed: 1, seconds: 3, sampleRate: 44_100)
        #expect(a == SyntheticClips.musicLike(seed: 1, seconds: 3, sampleRate: 44_100) && a != SyntheticClips.musicLike(seed: 2, seconds: 3, sampleRate: 44_100))
        #expect(abs(a.peak - 0.5) < 1e-6 && a.frames == 132_300)
        #expect(SyntheticClips.pcm16SHA256(a) == SyntheticClips.pcm16SHA256(SyntheticClips.musicLike(seed: 1, seconds: 3, sampleRate: 44_100)))
        let tone = SyntheticClips.tone(frequency: 1_000, amplitude: 0.5, seconds: 2, sampleRate: 16_000).channels[0]
        let crossings = zip(tone, tone.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        #expect(abs(crossings - 2_000) <= 1)
        #expect(SyntheticClips.silence(seconds: 1, sampleRate: 16_000).channels[0].allSatisfy { $0 == 0 })
        #expect(abs(SyntheticClips.whiteNoise(seed: 3, rmsDBFS: -20, seconds: 4, sampleRate: 16_000).rmsDBFS + 20) < 0.1)
        let clicks = SyntheticClips.clicks(seed: 1, seconds: 2, sampleRate: 16_000).channels[0]
        let loud = (0..<clicks.count).filter { abs(clicks[$0]) > 0.05 }
        #expect(loud.allSatisfy { ($0 % 4_000) < 80 } && Set(loud.map { $0 / 4_000 }) == [0, 1, 2, 3, 4, 5, 6, 7], "clicks sit on the quarter-second grid")
    }

    @Test("a clip's channels must agree, and the mixdown is their mean")
    func clip() throws {
        #expect(throws: VeilGardeFailure.self) { try AudioClip(sampleRate: 16_000, channels: [[0, 1], [0]]) }
        #expect(throws: VeilGardeFailure.self) { try AudioClip(sampleRate: 0, channels: [[0]]) }
        let stereo = try AudioClip(sampleRate: 16_000, channels: [[1, 0.5], [0, -0.5]])
        #expect(stereo.mono == [0.5, 0] && stereo.seconds == 2.0 / 16_000 && stereo.peak == 1)
    }
}
