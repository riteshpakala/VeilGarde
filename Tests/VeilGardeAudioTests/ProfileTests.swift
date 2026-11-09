//
//  ProfileTests.swift
//  VeilGardeAudioTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The two profiles' constants as the owner fixed them, the window's identities, the frame
//        count and the bit count a grid measures.
//

import Foundation
import Testing
@testable import VeilGardeAudio

@Suite("The two profiles")
struct ProfileTests {
    @Test("music is 44.1 kHz, N 2048, hop 512, 32 tile rows; speech is 16 kHz, N 1024, hop 256, 16 tile rows")
    func constants() {
        let m = SpectrogramProfile.music, s = SpectrogramProfile.speech
        #expect(m.sampleRate == 44_100 && m.fftSize == 2048 && m.hop == 512 && m.bins == 1024 && m.rows == 32 && m.minimumSeconds == 4 && m.aacKilobitsPerSecond == 128)
        #expect(s.sampleRate == 16_000 && s.fftSize == 1024 && s.hop == 256 && s.bins == 512 && s.rows == 16 && s.minimumSeconds == 8 && s.aacKilobitsPerSecond == 64)
        #expect(SpectrogramProfile.floorDB == -96 && SpectrogramProfile.ceilingDB == 0 && SpectrogramProfile.levels == 255)
        #expect(SpectrogramProfile.framesPerEval == 4096 && SpectrogramProfile.maximumSeconds == 600 && SpectrogramProfile.minimumRMSDBFS == -40)
        #expect(m.magnitudeReference == 512 && s.magnitudeReference == 256 && m.padding == 1024 && s.padding == 512)
        #expect(abs(m.tileSeconds - 0.3715) < 1e-3 && abs(m.tileHertz - 689.06) < 0.01 && abs(s.tileSeconds - 0.512) < 1e-9 && abs(s.tileHertz - 500) < 1e-9)
        #expect(SpectrogramProfile.inferred(rows: 32) == m && SpectrogramProfile.inferred(rows: 16) == s && SpectrogramProfile.inferred(rows: 20) == nil)
        #expect(SpectrogramProfile.named("music") == m && SpectrogramProfile.named("speech") == s && SpectrogramProfile.named("drums") == nil)
    }

    @Test("the periodic Hann: w[0] = 0, w[N/2] = 1, Σw = N/2, Σw² = 3N/8, and four copies sum to 1.5", arguments: [SpectrogramProfile.music, .speech])
    func window(profile: SpectrogramProfile) {
        let w = profile.window, N = profile.fftSize, H = profile.hop
        #expect(w.count == N && w[0] == 0 && abs(w[N / 2] - 1) < 1e-15)
        #expect(abs(w.reduce(0, +) - profile.windowSum) < 1e-9 && abs(w.map { $0 * $0 }.reduce(0, +) - profile.windowSquareSum) < 1e-9)
        for n in 0..<H {
            var sum = 0.0, squares = 0.0
            for k in 0..<4 { sum += w[n + k * H]; squares += w[n + k * H] * w[n + k * H] }
            #expect(abs(sum - 2) < 1e-12 && abs(squares - 1.5) < 1e-12, "sample \(n): \(sum), \(squares)")
        }
    }

    @Test("frames = 1 + ⌊L / hop⌋ and the bits a full-height grid measures")
    func counts() {
        let s = SpectrogramProfile.speech, m = SpectrogramProfile.music
        #expect([0, 1, 255, 256, 257, 192_000].map { s.frameCount(samples: $0) } == [1, 1, 1, 2, 2, 751])
        #expect(m.frameCount(samples: 352_800) == 690)
        #expect([3, 4].map { m.bits(columns: $0) } == [281, 406] && [5, 7, 23].map { s.bits(columns: $0) } == [259, 381, 1357])
        #expect(s.bits(columns: 0) == 0 && abs(s.seconds(column: 32) - 0.512) < 1e-12)
    }
}
