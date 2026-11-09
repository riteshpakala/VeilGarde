//
//  AudioFilesTests.swift
//  VeilGardeAudioTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The two doors on the CPU: a WAV written and read back, the fixtures read at their pinned
//        rate, channels and length, a file that is not audio refused; the resampler's length, level,
//        alignment and stop band; and the AAC round trip's length.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeAudio

@Suite("The doors: files and conversion")
struct AudioFilesTests {
    static func temporary(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vg-audio-\(UUID().uuidString)-\(name)")
    }

    @Test("a float WAV reads back bit for bit, a 16-bit one within a step")
    func wav() throws {
        var rng = SplitMix64(seed: 5)
        let channels = (0..<2).map { _ in (0..<4_410).map { _ in Float(rng.unit() * 1.8 - 0.9) } }
        let clip = try AudioClip(sampleRate: 44_100, channels: channels)
        let float = Self.temporary("f.wav"), int16 = Self.temporary("i.wav")
        defer { try? FileManager.default.removeItem(at: float); try? FileManager.default.removeItem(at: int16) }
        try AudioFiles.writeWAV(clip, to: float, depth: .float32)
        #expect(try AudioFiles.read(float) == clip)
        try AudioFiles.writeWAV(clip, to: int16, depth: .int16)
        let back = try AudioFiles.read(int16)
        #expect(back.sampleRate == 44_100 && back.channelCount == 2 && back.frames == 4_410)
        let worst = zip(back.channels.flatMap { $0 }, channels.flatMap { $0 }).map { abs($0 - $1) }.max() ?? 1
        #expect(worst <= 1.0 / 32_767, "largest 16-bit error \(worst)")
        let info = try AudioFiles.info(of: int16)
        #expect(info.sampleRate == 44_100 && info.channels == 2 && info.frames == 4_410)
    }

    @Test("the fixtures read at their rate, channels and length", arguments: [(Fixture.track, 44_100.0, 352_800), (Fixture.speech, 16_000.0, 192_000)])
    func fixtures(name: String, rate: Double, frames: Int) throws {
        try #require(Fixture.has(name), "fixture \(name) is missing: make it with `veilgarde audio export`")
        let clip = try AudioFiles.read(Fixture.url(name))
        #expect(clip.sampleRate == rate && clip.channelCount == 1 && clip.frames == frames)
        #expect(clip.rmsDBFS > -30, "\(name) at \(clip.rmsDBFS) dBFS")
    }

    @Test("a file that is not audio is refused")
    func notAudio() throws {
        let url = Self.temporary("x.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a sound".utf8).write(to: url)
        #expect(throws: VeilGardeFailure.self) { try AudioFiles.read(url) }
    }

    @Test("the resampler keeps the length, the level and the timing, and stops what the new rate cannot hold")
    func resampler() throws {
        let n = 441_000
        let sine = (0..<n).map { Float(0.5 * sin(2 * Double.pi * 1_000 * Double($0) / 44_100)) }
        let out = try AudioConverting.resampled(sine, from: 44_100, to: 16_000)
        #expect(out.count == Int((Double(n) * 16_000 / 44_100).rounded()))
        #expect(out == (try AudioConverting.resampled(sine, from: 44_100, to: 16_000)), "twice gives the same samples")
        let want = (0..<out.count).map { 0.5 * sin(2 * Double.pi * 1_000 * Double($0) / 16_000) }
        let interior = 1_000..<(out.count - 1_000)
        let worst = interior.map { abs(Double(out[$0]) - want[$0]) }.max() ?? 1
        #expect(worst < 0.01, "the resampled sine is off the expected one by \(worst): a delay or a gain")
        let tail = AudioClip.rmsDBFS(Array(out.suffix(160)))
        #expect(abs(tail - 20 * log10(0.5 / 2.0.squareRoot())) < 0.1, "the last 160 samples read \(tail) dBFS: the flush")
        let high = (0..<n).map { Float(0.5 * sin(2 * Double.pi * 10_000 * Double($0) / 44_100)) }
        let stopped = try AudioConverting.resampled(high, from: 44_100, to: 16_000)
        let level = AudioClip.rmsDBFS(Array(stopped[1_000..<(stopped.count - 1_000)]))
        #expect(level < -60, "a 10 kHz sine comes through at \(level) dBFS")
        #expect(try AudioConverting.resampled(sine, from: 44_100, to: 44_100) == sine)
    }

    @Test("the AAC round trip returns the clip's length at the rate asked for, or the highest the encoder offers below it")
    func aac() throws {
        try #require(Fixture.has(Fixture.track))
        let clip = try AudioFiles.read(Fixture.url(Fixture.track))
        let r = try AudioConverting.aacRoundTrip(clip, kilobitsPerSecond: 128)
        #expect(r.lengthDelta == 0, "the decode is \(r.lengthDelta) frames off")
        #expect(r.clip.sampleRate == clip.sampleRate && r.clip.channelCount == clip.channelCount)
        #expect(r.requestedKilobitsPerSecond == 128 && r.usedKilobitsPerSecond == 128)
        #expect(r.kilobitsPerSecond > 110 && r.kilobitsPerSecond < 140, "the stream runs at \(r.kilobitsPerSecond) kb/s")
        #expect(AudioConverting.aacBitRates(sampleRate: 16_000, channels: 1).max() == 48)
        let speech = try AudioConverting.aacRoundTrip(SyntheticClips.musicLike(seed: 2, seconds: 3, sampleRate: 16_000), kilobitsPerSecond: 64)
        #expect(speech.usedKilobitsPerSecond == 48 && speech.lengthDelta == 0)
    }
}
