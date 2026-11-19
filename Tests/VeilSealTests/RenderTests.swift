//
//  RenderTests.swift
//  VeilSealTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The pictures a mark is shown with, on the CPU: a record's digest is 640 × 800 and the same
//        pixels every time (pinned by digest), a detection's digest draws for every verdict, an overlay
//        scales a large image to 1,600 px under its header and keeps a small one whole on a 640-px canvas,
//        and the bitmap font's glyphs are five by seven.
//

import CoreGraphics
import Foundation
import Testing
import VeilGardeCore
import VeilGardeLens
@testable import VeilSeal

@Suite("Mark pictures")
struct RenderTests {
    static func pixels(_ png: Data) throws -> (width: Int, height: Int, sha: String) {
        let image = try ImageDecoding.cgImage(data: png)
        return (image.width, image.height, ContentHash.sha256Hex(Data(try MarkFixture.bytes(image))))
    }

    static func detection(_ verdict: SealVerdict) -> SealDetection {
        let record = MarkFixture.record()
        let found = verdict == .marked || verdict == .contentMismatch || verdict == .unknownID
        let message = PayloadCode.message(id: MarkFixture.id, key: .default)
        let soft = PayloadCode.encode(message).enumerated().map { i, bit -> Float in (bit == 1 ? 1 : -1) * Float(1 + i % 5) }
        let reading = MarkReading(id: found ? MarkFixture.id : nil, pilotZ: found ? 7.25 : 0.5, pilotAgreement: 0.9, pilotBits: 900, phaseX: 5, phaseY: 11,
                                  periodRow: 3, periodCol: 4, message: message, codedSoft: soft, codewordAgreement: found ? 0.97 : nil,
                                  tiles: 999, reads: 32, seconds: 9.5)
        let codes = record.signature.tileCodes
        let match = verdict == .marked || verdict == .passiveMatch || verdict == .contentMismatch
            ? MatchResult(offsetX: 2, offsetY: 3, phaseX: 5, phaseY: 11, score: verdict == .contentMismatch ? 0.52 : 0.96, bitsCompared: 640,
                          zScore: 23, matched: verdict != .contentMismatch)
            : nil
        let agreement = match.map { _ in Matcher.agreement(crop: codes, stored: codes, dx: 0, dy: 0, originX: 5, originY: 11) }
        let markMap = found ? TileMap(rows: 4, cols: 4, values: (0..<16).map { Float($0 % 3) - 1 }, weights: [Float](repeating: 1, count: 16), originX: 5, originY: 11) : nil
        var d = SealDetection(verdict: verdict, reading: reading, record: verdict == .unknownID || verdict == .none ? nil : record, match: match,
                              agreement: agreement, markMap: markMap, consistent: verdict == .marked ? true : nil, exactBytes: false,
                              keyFingerprint: SealKey.default.fingerprint, width: 480, height: 400, seconds: 9.5, summary: "")
        d.summary = BurgundySeal.summary(d, haveStore: true)
        return d
    }

    @Test("a record's digest is 640 × 800 and the pinned pixels")
    func recordDigest() throws {
        let png = try BurgundySeal.digest(MarkFixture.record())
        let p = try Self.pixels(png)
        #expect(p.width == 640 && p.height == 800)
        #expect(p.sha == "f08a4b327a76158090bd247ab5685519d171600893e1f53308b1192b8ec31e59")
        #expect(try BurgundySeal.digest(MarkFixture.record()) == png, "drawn twice, the same bytes")
    }

    @Test("a detection's digest draws for every verdict", arguments: SealVerdict.allCases)
    func detectionDigest(verdict: SealVerdict) throws {
        let p = try Self.pixels(try BurgundySeal.digest(Self.detection(verdict)))
        #expect(p.width == 640 && p.height == 800)
    }

    @Test("an overlay: a large image scaled to 1,600 px under a 64-px header; a small one whole on a 640-px canvas")
    func overlay() throws {
        let large = try PNGEncoding.png(rgb: [UInt8](repeating: 128, count: 3200 * 1000 * 3), width: 3200, height: 1000)
        let big = try Self.pixels(try BurgundySeal.overlay(Self.detection(.marked), query: try ImageDecoding.cgImage(data: large)))
        #expect(big.width == 1600 && big.height == 64 + 500 + 8)
        let small = try PNGEncoding.png(rgb: [UInt8](repeating: 90, count: 480 * 400 * 3), width: 480, height: 400)
        for layer in OverlayLayer.allCases {
            let p = try Self.pixels(try BurgundySeal.overlay(Self.detection(.passiveMatch), query: try ImageDecoding.cgImage(data: small), layer: layer))
            #expect(p.width == 640 && p.height == 64 + 400 + 8)
        }
    }

    @Test("verdict summaries say what happened")
    func summaries() {
        #expect(Self.detection(.marked).summary == "Marked · id 0123456789abcdef · recorded as “Ana” · z 7.2 · passive 0.96")
        #expect(Self.detection(.none).summary == "No mark · no id passes its check over 999 tiles", "never the pilots' z without an id")
        #expect(Self.detection(.unknownID).summary.hasPrefix("Unknown id · 0123456789abcdef is not in this store"))
        #expect(Self.detection(.contentMismatch).summary.hasPrefix("Content mismatch · id 0123456789abcdef is recorded for another image (passive 0.52)"))
        #expect(Self.detection(.passiveMatch).summary.contains("recorded as “Ana”"))
    }

    @Test("the font: seven rows of five bits a glyph, lowercase drawn as uppercase, typographic quotes and dashes as typewriter ones, the rest as ?")
    func font() {
        for (ch, rows) in BitmapFont.glyphs {
            #expect(rows.count == 7, "\(ch)")
            #expect(rows.allSatisfy { $0 < 32 }, "\(ch)")
        }
        #expect(BitmapFont.glyph("a") == BitmapFont.glyph("A"))
        #expect(BitmapFont.glyph("🙂") == BitmapFont.glyph("?"))
        #expect(BitmapFont.glyph("“") == BitmapFont.glyph("\"") && BitmapFont.glyph("”") == BitmapFont.glyph("\""), "a summary's “label” is not ?LABEL?")
        #expect(BitmapFont.glyph("’") == BitmapFont.glyph("'") && BitmapFont.glyph("—") == BitmapFont.glyph("-"))
        #expect(BitmapFont.width("ABC", scale: 2) == 3 * 12 - 2)
        #expect(BitmapFont.fitted("ABCDEFGHIJ", pixels: 6 * 5 - 1, scale: 1) == "ABCD…")
        #expect(BitmapFont.fitted("ABC", pixels: 100, scale: 1) == "ABC")
    }
}
