//
//  AcceptanceTests.swift
//  VeilGardeAudioTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The audio acceptance's sample and its kill criterion. On the CPU: segments, the seeded
//        sample in folder order, each of the four rules killing on its own, and the image lane's
//        summarize agreeing with the audio one on the same rows, so the two carriers share one
//        criterion. On the GPU: four synthetic clips run end to end.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeAudio

@Suite("The audio acceptance")
struct AcceptanceTests {
    static func row(_ i: Int, cut: Double = 0.95, error: Double = 0, reencode: Double = 0.9, cross: Double = 0.5) -> AudioAcceptanceClip {
        let m = { (score: Double) in matchResult(score: score, bits: 600) }
        let metrics = AudioRoundTripMetrics(samples: 1, snrDB: 120, maxAbsoluteError: 0, logSpectralDeviationDB: 0)
        return AudioAcceptanceClip(
            path: "/c\(i).wav", segment: 0, kind: "file", nativeRate: 44_100, channels: 1, seconds: 10, frames: 862, rmsDBFS: -20, signedBits: 3156,
            balance: [0.5, 0.5, 0.5, 0.5], floorShare: 0.1, frMean: 1, frSpread: 0.1, selfMatch: matchResult(score: 1, bits: 3156),
            cut: .init(startSample: 0, length: 220_500, expectedColumn: 0, seconds: 0), cutMatch: m(cut), cutSubHopOffset: 0, cutOffsetError: error, alignedCutMatch: m(cut),
            reencode: .init(match: m(reencode), lagSamples: 0, lengthDelta: 0, requestedKilobitsPerSecond: 128, usedKilobitsPerSecond: 128, kilobitsPerSecond: 126.5), cross: m(cross), speed: [:], gain: m(1), pcm16: m(1),
            noise: m(0.9), roundTripExact: metrics, roundTripImage: metrics, elapsed: 1)
    }

    /// The audio row as the image lane's row, through JSON (AcceptanceImage is Codable).
    static func imageRow(_ r: AudioAcceptanceClip) throws -> AcceptanceImage {
        func object(_ m: MatchResult) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) }
        let fields: [String: Any] = [
            "path": r.path, "label": 0, "width": r.frames, "height": 1024, "signedBits": r.signedBits, "balance": r.balance, "selfMatch": try object(r.selfMatch),
            "crop": ["x": r.cut.expectedColumn, "y": 0, "width": r.frames / 2, "height": 1024], "cropMatch": try object(r.cutMatch), "cropOffsetError": r.cutOffsetError,
            "jpeg": try object(r.reencode.match), "cross": try object(r.cross), "resized": [String: Any](), "seconds": r.elapsed,
        ]
        return try JSONDecoder().decode(AcceptanceImage.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    static let cases: [(String, [AudioAcceptanceClip], Bool)] = [
        ("clean", (0..<10).map { row($0) }, false),
        ("cuts miss", (0..<10).map { row($0, cut: $0 < 5 ? 0.6 : 0.95) }, true),
        ("re-encodes miss", (0..<10).map { row($0, reencode: 0.7) }, true),
        ("false matches", (0..<10).map { row($0, cross: $0 < 2 ? 0.96 : 0.5) }, true),
        ("no threshold reaches 80% recall", (0..<10).map { row($0, error: $0 < 3 ? 2 : 0) }, true),
    ]

    @Test("each rule kills on its own, and the image lane's summarize agrees on the same rows", arguments: 0..<5)
    func criterion(index: Int) throws {
        let (name, rows, killed) = Self.cases[index]
        let audio = AudioAcceptance.summarize(rows, settings: AudioAcceptanceSettings())
        let image = WatermarkAcceptance.summarize(try rows.map(Self.imageRow), settings: AcceptanceSettings())
        #expect(audio.killed == killed && audio.reasons.count == (killed ? 1 : 0), "\(name): \(audio.reasons)")
        #expect(audio.killed == image.killed && audio.reasons.count == image.reasons.count, "\(name): the carriers disagree")
        #expect(audio.selfMatchRate == image.selfMatchRate && audio.cutMatchRate == image.cropMatchRate && audio.reencodeMedianScore == image.jpegMedianScore)
        #expect(audio.crossFalseMatchRate == image.crossFalseMatchRate && audio.operatingThreshold == image.operatingThreshold
                && audio.operatingFalseMatchRate == image.operatingFalseMatchRate && audio.operatingRecall == image.operatingRecall)
    }

    @Test("segments run back to back from 0, and the sample is seeded and keeps the folder's order")
    func sample() throws {
        #expect(AudioAcceptanceSample.segments(total: 161.2, segment: 10) == 16 && AudioAcceptanceSample.segments(total: 9.9, segment: 10) == 0)
        let items = (0..<60).map { AudioAcceptanceSample.Item(url: URL(fileURLWithPath: "/m/t\($0 / 20).aif"), segment: $0 % 20, startSeconds: Double($0 % 20) * 10, durationSeconds: 10) }
        let a = AudioAcceptanceSample.sample(items, n: 12, seed: 0)
        #expect(a.count == 12 && a == AudioAcceptanceSample.sample(items, n: 12, seed: 0) && a != AudioAcceptanceSample.sample(items, n: 12, seed: 1))
        let order = a.map { items.firstIndex(of: $0)! }
        #expect(order == order.sorted())
        #expect(AudioAcceptanceSample.sample(items, n: 100, seed: 0) == items)
        if Fixture.has(Fixture.track) {
            let segments = try AudioAcceptanceSample.items(for: [Fixture.url(Fixture.track)], segmentSeconds: 4)
            #expect(segments.map(\.startSeconds) == [0, 4] && segments.map(\.label) == ["\(Fixture.track)#0", "\(Fixture.track)#1"])
            let loaded = try AudioAcceptanceSample.load(segments)
            #expect(loaded.map { $0.clip.frames } == [176_400, 176_400])
        }
    }
}

extension AudioMLXSuites {
    @Suite("The audio acceptance on the GPU", .serialized)
    struct AcceptanceOnGPU {
        @Test("four synthetic clips run end to end; each matches itself")
        func endToEnd() throws {
            var settings = AudioAcceptanceSettings()
            settings.profile = SpectrogramProfile.speech.name
            var streamed = 0
            let report = try AudioAcceptance.run(AudioAcceptance.synthetic(count: 4, profile: .speech), settings: settings, measured: { _ in streamed += 1 })
            #expect(report.clips.count == 4 && streamed == 4 && report.summary.clips == 4 && report.summary.selfMatchRate == 1)
            #expect(report.clips[0].speed.count == 2 && report.clips[1].speed.isEmpty)
            print("audio acceptance, 4 synthetic speech-profile clips: cut \(report.summary.cutMatchRate), AAC median \(report.summary.reencodeMedianScore), killed \(report.summary.killed) \(report.summary.reasons)")
        }
    }
}
