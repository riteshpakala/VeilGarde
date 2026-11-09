//
//  Fixture.swift
//  VeilGardeAudioTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What the audio tests read by repo path: the two clips under Fixtures/ (8 s of the owner's
//        track at 44.1 kHz, 12 s of an Apple voice at 16 kHz) and the pins each clip and the
//        synthetic clip yield, captured once on purpose (VEILGARDE_AUDIO_PIN=1) and held with exact
//        equality after, as the watermark's ResidualTests hold the crops.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeAudio

enum Fixture {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "Tests" { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent()
    }()

    static let folder = repoRoot.appendingPathComponent("Tests/VeilGardeAudioTests/Fixtures")
    static let track = "raos_theme_30s_8s.wav"
    static let speech = "say_samantha_12s.wav"

    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
    static func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }

    /// A clip's fragility grid, signature id and picture hash under one profile, with the measured round trips.
    struct Pin: Codable, Equatable {
        struct Measured: Codable, Equatable {
            var exactSNR: Double
            var imageSNR: Double
            var resampled: Bool
        }
        var clip: String
        var source: String
        var profile: String
        var rows: Int
        var cols: Int
        var bits: Int
        var cid: String
        var graySHA256: String
        var fr: [Double]
        var measured: Measured
        var date: String
    }

    static func pinURL(_ name: String) -> URL { folder.appendingPathComponent("\(name).fr.json") }

    static func pin(_ name: String) throws -> Pin? {
        let url = pinURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Pin.self, from: Data(contentsOf: url))
    }

    static func capture(_ pin: Pin, as name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONCoding.write(pin, to: pinURL(name))
    }

    static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// The fresh pin of `clip` under `profile`, every number measured now.
    static func fresh(_ clip: AudioClip, named name: String, source: String, profile: SpectrogramProfile) throws -> Pin {
        let signal = try AnalysisSignal(clip, profile: profile)
        let image = SpectrogramImage(Spectrogram(signal))
        let grid = try AudioWatermark.fragility(image)
        let signature = try AudioWatermark.sign(image)
        let exact = AudioRoundTrip.exact(signal).metrics
        let viaImage = AudioRoundTrip.throughImage(signal).metrics
        return Pin(clip: name, source: source, profile: profile.name, rows: grid.rows, cols: grid.cols, bits: signature.measuredBits, cid: signature.cid,
                   graySHA256: image.graySHA256, fr: grid.values.map(Double.init),
                   measured: .init(exactSNR: exact.snrDB, imageSNR: viaImage.snrDB, resampled: clip.sampleRate != profile.sampleRate), date: today)
    }

    /// VEILGARDE_AUDIO_PIN=1 writes the pins instead of holding them: a re-pin is always on purpose.
    static let pinning = ProcessInfo.processInfo.environment["VEILGARDE_AUDIO_PIN"] == "1"

    /// Holds `fresh` to the pin `name`; with VEILGARDE_AUDIO_PIN=1, writes it.
    static func hold(_ fresh: Pin, as name: String) throws {
        if pinning {
            try capture(fresh, as: name)
            print("pinned \(name): \(fresh.rows)×\(fresh.cols) tiles, \(fresh.bits) bits, cid \(fresh.cid.prefix(16)), exact \(fresh.measured.exactSNR) dB, picture \(fresh.measured.imageSNR) dB")
            return
        }
        guard let pinned = try pin(name) else {
            Issue.record("no pin \(name): capture it on purpose with VEILGARDE_AUDIO_PIN=1")
            return
        }
        #expect(pinned.rows == fresh.rows && pinned.cols == fresh.cols, "\(name): grid \(fresh.rows)×\(fresh.cols), pinned \(pinned.rows)×\(pinned.cols)")
        #expect(pinned.cid == fresh.cid, "\(name): cid moved from \(pinned.cid.prefix(16)) to \(fresh.cid.prefix(16))")
        #expect(pinned.graySHA256 == fresh.graySHA256, "\(name): the picture's bytes moved")
        let worst = zip(pinned.fr, fresh.fr).map { abs($0 - $1) }.max() ?? .infinity
        #expect(pinned.fr == fresh.fr, "\(name): the fragility moved, largest difference \(worst)")
        #expect(pinned.source == fresh.source, "\(name): the clip itself changed")
    }

    static func fileSHA256(_ url: URL) throws -> String { "file:" + (try ContentHash.sha256Hex(fileAt: url)) }
}

/// A MatchResult by its fields; its memberwise init is the watermark's own.
func matchResult(score: Double, bits: Int, offsetX: Int = 0, offsetY: Int = 0, phaseX: Int = 0, matched: Bool? = nil) -> MatchResult {
    let json = """
    {"offsetX": \(offsetX), "offsetY": \(offsetY), "phaseX": \(phaseX), "phaseY": 0, "score": \(score), "bitsCompared": \(bits), "zScore": 0, "matched": \(matched ?? (score >= 0.75 && bits >= 256))}
    """
    return try! JSONDecoder().decode(MatchResult.self, from: Data(json.utf8))
}
