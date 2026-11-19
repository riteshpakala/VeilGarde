//
//  RenderTests.swift
//  VeilSealTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The words and pictures a seal is shown with, on the CPU: each verdict's summary; the wax (burgundy
//        at its centre, clear at its corners, the same pixels twice, a rim of its id's own) and its ghost; the
//        detection graphic and the digest at the layout's size; the bitmap font's glyphs (five by seven).
//

import CoreGraphics
import Foundation
import Testing
import VeilGardeCore
import VeilGardeLens
@testable import VeilSeal

@Suite("Seal pictures")
struct RenderTests {
    static func pixels(_ png: Data) throws -> (width: Int, height: Int, sha: String) {
        let image = try ImageDecoding.cgImage(data: png)
        return (image.width, image.height, ContentHash.sha256Hex(Data(try MarkFixture.bytes(image))))
    }

    static func detection(_ verdict: SealVerdict, interlaced: SealID? = nil) -> SealDetection {
        let record = MarkFixture.record()
        let match = SealMatch(id: record.id, label: "Ana", createdAt: record.createdAt, candidates: 300, inliers: 240, retraced: 80, possible: 91,
                              coverage: 0.25, cells: 16, agreement: 0.4, scale: 0.5, projective: false, residualAgreement: 0.8, transform: .identity, found: verdict == .sealed,
                              anchors: [], trails: [], portion: [])
        var d = SealDetection(verdict: verdict, match: verdict == .unknownSeal || verdict == .contentMismatch ? nil : match, interlaced: interlaced,
                              width: 512, height: 512, anchors: 900, seals: 3, keyFingerprint: SealKey.default.fingerprint, seconds: 1, summary: "")
        d.summary = BurgundySeal.summary(d, haveStore: true)
        return d
    }

    @Test("verdict summaries say what happened")
    func summaries() {
        let id = MarkFixture.record().id.hex
        #expect(Self.detection(.sealed).summary == "sealed: “Ana” (\(id)) — 240 anchors agree, 80 of 91 hops retraced, 25% of the original at 0.50×")
        #expect(Self.detection(.none).summary.hasPrefix("no seal among 3: the nearest, “Ana”"))
        #expect(Self.detection(.unknownSeal, interlaced: SealID(1)).summary.hasPrefix("unknown seal: the interlace names 0000000000000001"))
        #expect(Self.detection(.contentMismatch, interlaced: SealID(1)).summary.hasPrefix("content mismatch: the interlace names 0000000000000001"))
        #expect(Self.detection(.interlaceOnly, interlaced: SealID(1)).summary.contains("reads only in part"))
    }

    static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    @Test("the wax: burgundy at the centre, clear at the corners, the same pixels twice, its rim its id's own; the ghost is faint")
    func wax() throws {
        let a = try WaxSeal.image(id: SealID(0xabc), size: 200), b = try WaxSeal.image(id: SealID(0xabc), size: 200)
        #expect(a.width == 200 && a.height == 200)
        let pa = Self.rgba(a)
        #expect(pa == Self.rgba(b))
        #expect(pa != Self.rgba(try WaxSeal.image(id: SealID(0xdef), size: 200)), "another id, another rim")
        let centre = (100 * 200 + 100) * 4
        #expect(pa[centre + 3] == 255 && Int(pa[centre]) > Int(pa[centre + 1]) + 30 && Int(pa[centre]) > Int(pa[centre + 2]) + 20, "burgundy")
        #expect(pa[3] == 0 && pa[(200 * 200 - 1) * 4 + 3] == 0, "the corners are clear")
        let ghost = Self.rgba(try WaxSeal.ghost(size: 200))
        #expect(stride(from: 3, to: ghost.count, by: 4).allSatisfy { ghost[$0] <= 141 }, "never more than 55% opaque")
        #expect(RRMarkMask.bits.count == RRMarkMask.width * RRMarkMask.height && RRMarkMask.bits.contains(true) && RRMarkMask.bits.contains(false))
    }

    @Test("the detection graphic draws for every verdict, with and without the picture, at the layout's size", arguments: SealVerdict.allCases)
    func detectionGraphic(verdict: SealVerdict) throws {
        let d = Self.detection(verdict, interlaced: verdict == .sealed ? nil : SealID(1))
        let layout = SealGraphic.layout(width: d.width, height: d.height)
        for picture in [nil, try MarkFixture.stranger(seed: 1)] {
            let png = try BurgundySeal.graphic(d, picture: picture)
            let (w, h, _) = try Self.pixels(png)
            #expect(w == layout.width && h == layout.height)
        }
        #expect(layout.pictureW == 520 && layout.pictureH == 520, "a small picture drawn at a 520-px side")
        #expect(SealGraphic.layout(width: 4000, height: 3000).pictureW == 1000, "a large one fitted to 1000 × 760")
    }

    @Test("a seal's digest draws with and without its picture")
    func sealDigest() throws {
        let record = MarkFixture.record()
        for picture in [nil, try MarkFixture.stranger(seed: 2)] {
            let (w, h, _) = try Self.pixels(try BurgundySeal.digest(record, picture: picture))
            #expect(w == SealGraphic.layout(width: 512, height: 512).width && h == SealGraphic.layout(width: 512, height: 512).height)
        }
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
