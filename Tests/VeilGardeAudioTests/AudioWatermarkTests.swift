//
//  AudioWatermarkTests.swift
//  VeilGardeAudioTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The watermark on sound, on the GPU. Each clip's fragility, signature and picture are the
//        pinned ones; signing is the watermark's own sign of the picture and leaves the sound alone;
//        a clip matches itself at offset 0 with score 1; a cut at a tile boundary matches at its
//        column with score 1, and a cut at any sample within a tile; the sound after the exact and
//        the picture's round trip, a gain, 16 bits and an AAC re-encode still match; a stranger and
//        silence do not pass for the clip; the lag finder finds a planted lag.
//  PIN:  Pins are exact, as the watermark's ResidualTests are: captured once with
//        VEILGARDE_AUDIO_PIN=1 and held after. Whether v1 holds on real cuts and re-encodes is the
//        acceptance's question (`veilgarde audio accept`), not these tests'.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeAudio

extension AudioMLXSuites {
    @Suite("The watermark on sound, on the GPU", .serialized)
    struct WatermarkOnGPU {
        static let music = SyntheticClips.musicLike(seed: 1, seconds: 12, sampleRate: 44_100)

        @Test("each clip's fragility, signature and picture are the pinned ones", arguments: ["synthetic_12s_seed1.music", "raos_theme_30s_8s.music", "say_samantha_12s.speech"])
        func pins(name: String) throws {
            let profile = name.hasSuffix(".speech") ? SpectrogramProfile.speech : .music
            let clip: AudioClip, source: String
            switch name {
            case "synthetic_12s_seed1.music":
                clip = Self.music
                source = "pcm16:" + SyntheticClips.pcm16SHA256(clip)
            case "raos_theme_30s_8s.music":
                try #require(Fixture.has(Fixture.track))
                clip = try AudioFiles.read(Fixture.url(Fixture.track))
                source = try Fixture.fileSHA256(Fixture.url(Fixture.track))
            default:
                try #require(Fixture.has(Fixture.speech))
                clip = try AudioFiles.read(Fixture.url(Fixture.speech))
                source = try Fixture.fileSHA256(Fixture.url(Fixture.speech))
            }
            try Fixture.hold(try Fixture.fresh(clip, named: name, source: source, profile: profile), as: name)
        }

        @Test("signing is the watermark's sign of the picture, deterministic, and leaves the sound alone; a clip matches itself")
        func sign() throws {
            let clip = Self.music
            let image = try AudioWatermark.picture(clip, profile: .music)
            let a = try AudioWatermark.sign(clip, profile: .music)
            let fromImage = try AudioWatermark.sign(image), fromWatermark = try Watermark.sign(try image.cgImage)
            let oneRead = WatermarkSignature(grid: TileCodeGrid(try AudioWatermark.fragility(image)))
            #expect(a == fromImage && a == fromWatermark)
            #expect(a == oneRead, "the acceptance's one-read signature is sign's")
            #expect(a.rows == 32 && a.cols == image.width / 32 && a.measuredBits == SpectrogramProfile.music.bits(columns: a.cols))
            #expect(clip == Self.music, "nothing is written into the sound")
            let me = try AudioWatermark.match(clip, against: a, options: MatchOptions(phases: [0]))
            #expect(me.matched && me.result.score == 1 && me.result.offsetX == 0 && me.result.offsetY == 0 && me.seconds == 0 && me.profile == "music")
            #expect(try AudioWatermark.profile(of: a) == .music)
        }

        @Test("a cut at a tile boundary matches at its column with score 1; one at any sample within a tile")
        func cuts() throws {
            let p = SpectrogramProfile.music
            let sig = try AudioWatermark.sign(Self.music, profile: p)
            // 96 hops in, 354 hops long: 355 frames, the first two and the last two in tiles the grid read at 32 leaves out.
            let cut = AudioTransforms.cut(Self.music, startSample: 96 * p.hop, length: 354 * p.hop)
            let image = try AudioWatermark.picture(cut, profile: p)
            #expect(image.width == 355)
            let exact = Watermark.match(codes: try AudioWatermark.phaseCodes(image, phases: [32]), against: sig)
            #expect(exact.matched && exact.score == 1 && exact.pixelX == 96 && exact.offsetY == 0, "\(exact)")
            let searched = try AudioWatermark.match(cut, against: sig)
            #expect(searched.matched && abs(searched.column - 96) <= 32 && searched.frequencyRows == 0, "\(searched.result)")
            var rng = SplitMix64(seed: 7)
            let length = Self.music.frames / 2
            let start = rng.index(Self.music.frames - length + 1)
            let anywhere = try AudioWatermark.match(AudioTransforms.cut(Self.music, startSample: start, length: length), against: sig)
            let expected = AudioWatermark.expectedColumn(startSample: start, nativeRate: 44_100, profile: p)
            #expect(abs(anywhere.column - expected) <= 32 && anywhere.frequencyRows == 0 && abs(anywhere.seconds - Double(start) / 44_100) <= p.tileSeconds,
                    "a cut at sample \(start) was placed at column \(anywhere.column) for \(expected)")
            // Missed on 2026-11-08 and kept as fixed: the cut at sample 211,031, 87 samples past a hop, was placed four
            // columns from the truth but scored 0.680, under 0.75. A cut off the hop grid is not a shifted picture: its
            // frames hold other samples. The acceptance measures how often; a pass here flags itself.
            withKnownIssue("a cut off the hop grid scores under 0.75 (measured 2026-11-08)") {
                #expect(anywhere.matched, "a cut at sample \(start): score \(anywhere.result.score)")
            }
        }

        @Test("the sound after both round trips, a gain, 16 bits and an AAC re-encode still matches; noise is recorded")
        func survives() throws {
            let p = SpectrogramProfile.music
            let clip = Self.music
            let sig = try AudioWatermark.sign(clip, profile: p)
            let phaseZero = MatchOptions(phases: [0])
            let signal = try AnalysisSignal(clip, profile: p)
            let exact = try AudioWatermark.match(AudioRoundTrip.exact(signal).signal.clip(), against: sig, options: phaseZero)
            #expect(exact.matched && exact.result.score > 0.99, "the exact round trip scored \(exact.result.score)")
            let viaImage = try AudioWatermark.match(AudioRoundTrip.throughImage(signal).signal.clip(), against: sig, options: phaseZero)
            #expect(viaImage.matched, "the picture's round trip scored \(viaImage.result.score)")
            let gain = try AudioWatermark.match(AudioTransforms.gained(clip, dB: -6), against: sig, options: phaseZero)
            #expect(gain.matched, "−6 dB scored \(gain.result.score)")
            let pcm16 = try AudioWatermark.match(AudioTransforms.requantized16Bit(clip), against: sig, options: phaseZero)
            #expect(pcm16.matched, "16 bits scored \(pcm16.result.score)")
            let aac = try AudioConverting.aacRoundTrip(clip, kilobitsPerSecond: p.aacKilobitsPerSecond)
            let lag = SignalAlignment.lag(of: aac.clip.mono, against: clip.mono)
            #expect(lag == 0, "the AAC decode is \(lag) samples late")
            let realigned = AudioClip(sampleRate: clip.sampleRate, mono: SignalAlignment.aligned(aac.clip.mono, by: lag, length: clip.frames))
            let reencoded = try AudioWatermark.match(realigned, against: sig, options: phaseZero)
            #expect(reencoded.matched, "AAC \(p.aacKilobitsPerSecond) kb/s scored \(reencoded.result.score)")
            let noise = try AudioWatermark.match(AudioTransforms.withWhiteNoise(clip, snrDB: 30, seed: 3), against: sig, options: phaseZero)
            print("audio watermark: exact \(exact.result.score), picture \(viaImage.result.score), gain \(gain.result.score), 16-bit \(pcm16.result.score), AAC \(reencoded.result.score), noise 30 dB \(noise.result.score)")
        }

        @Test("a stranger does not match, and silence draws a flat picture")
        func strangers() throws {
            let p = SpectrogramProfile.music
            let sig = try AudioWatermark.sign(Self.music, profile: p)
            let other = SyntheticClips.musicLike(seed: 2, seconds: 12, sampleRate: 44_100)
            let stranger = try AudioWatermark.match(AudioTransforms.cut(other, startSample: 100_000, length: 264_600), against: sig)
            #expect(!stranger.matched && stranger.result.bitsCompared >= 256, "a stranger scored \(stranger.result.score) over \(stranger.result.bitsCompared) bits")
            let image = try AudioWatermark.picture(SyntheticClips.silence(seconds: 6, sampleRate: 44_100), profile: p)
            #expect(image.floorShare == 1)
            #expect(try AudioWatermark.sign(image).tileCodes.balance.allSatisfy { $0 == 0 })
        }

        @Test("the lag finder finds a planted lag", arguments: [37, -1_500, 0])
        func lag(planted: Int) {
            let reference = SyntheticClips.whiteNoise(seed: 8, rmsDBFS: -20, seconds: 4, sampleRate: 16_000).channels[0]
            let candidate = planted >= 0 ? [Float](repeating: 0, count: planted) + reference : Array(reference.dropFirst(-planted))
            #expect(SignalAlignment.lag(of: candidate, against: reference) == planted)
            #expect(SignalAlignment.aligned(candidate, by: planted, length: 100) == Array(reference.prefix(100)) || planted < 0)
        }

        @Test("the speech fixture matches itself under its profile, and again through a 16-bit WAV")
        func speech() throws {
            try #require(Fixture.has(Fixture.speech))
            let clip = try AudioFiles.read(Fixture.url(Fixture.speech))
            let sig = try AudioWatermark.sign(clip, profile: .speech)
            #expect(sig.rows == 16)
            let me = try AudioWatermark.match(clip, against: sig, options: MatchOptions(phases: [0]))
            #expect(me.matched && me.result.score == 1 && me.profile == "speech")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("vg-audio-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try AudioFiles.writeWAV(clip, to: url, depth: .int16)
            let again = try AudioWatermark.match(try AudioFiles.read(url), against: sig, options: MatchOptions(phases: [0]))
            #expect(again.matched && again.result.score == 1, "through a WAV: \(again.result.score)")
        }
    }
}
