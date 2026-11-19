//
//  MarkTests.swift
//  VeilSealTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The pixel mark end to end, on the GPU: an unmarked parity crop reads no id after the whole
//        phase search, and is too small to carry a mark; the 2048 × 1024 composite marked through
//        BurgundySeal stays within L∞ 3 and 40 dB, moves R, G and B together, self-matches its record at
//        offset 0 with score 1, is detected as marked from its bytes and from a crop at an odd offset
//        (found at its exact phase, where the passive match lands on the crop's origin), and is refused
//        a second mark. Whether the mark survives a camera roll's worth of crops and re-encodes is
//        `watermark embed-accept`'s question, not these tests'.
//

import CoreGraphics
import Foundation
import Testing
import VeilGardeCore
import VeilGardeLens
@testable import VeilSeal

extension WatermarkMLXSuites {
    @Suite("The pixel mark on the GPU", .serialized)
    struct MarkGPU {
        @Test("an unmarked parity crop reads no id at any phase, and is too small to mark", arguments: ["crop_ben.png", "crop_fox.png"])
        func unmarked(name: String) throws {
            let reading = MarkDecoder.read(try NativePlane(try ImageDecoding.cgImage(contentsOf: Fixture.crop(name))))
            #expect(reading.id == nil)
            // Phase (0, 0), every y at x 0 and 16, every x at the three best y's apart: one window, so nothing
            // is read twice.
            #expect(reading.tiles == 225 && reading.reads == 154)
            #expect(throws: MarkFailure.tooSmall(tiles: 225, needed: MarkDecoder.minimumTiles)) {
                _ = try BurgundySeal.embed(data: try Data(contentsOf: Fixture.crop(name)), name: name, id: MarkFixture.id, store: nil)
            }
        }

        @Test("the composite through BurgundySeal: bounded, R G B together, marked from its bytes and from a crop at (37, 91); refused a second mark")
        func facade() throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vgm1-facade-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = try SealStore(directory: folder)
            let source = try MarkFixture.composite()
            let png = try PNGEncoding.png(rgb: try MarkFixture.bytes(source), width: 2048, height: 1024)
            var lines: [String] = []
            let marked = try BurgundySeal.embed(data: png, name: "composite.png", label: "the composite", store: store, progress: { lines.append($0.line) })
            let r = marked.report
            #expect(r.linf <= 3 && r.psnr >= 40, "L∞ \(r.linf), PSNR \(r.psnr)")
            #expect(r.verified, "satisfied \(r.satisfied), pilot z \(r.pilotZ), agreement \(r.codewordAgreement ?? -1)")
            #expect(lines.contains { $0.hasPrefix("embedding · step 1/") })
            #expect(try store.record(for: marked.record.id) == marked.record)
            #expect(marked.record.pngSHA256 == ContentHash.sha256Hex(marked.png))

            let decoded = try ImageDecoding.cgImage(data: marked.png)
            let before = try MarkFixture.bytes(source), after = try MarkFixture.bytes(decoded)
            var moved = 0, uneven = 0
            for i in 0..<(before.count / 3) {
                let d = (0..<3).map { Int(after[3 * i + $0]) - Int(before[3 * i + $0]) }
                if d[0] != d[1] || d[1] != d[2] || abs(d[0]) > 3 { uneven += 1 }
                if d[0] != 0 { moved += 1 }
            }
            #expect(uneven == 0 && moved > 0, "\(uneven) pixels moved R, G and B apart or past 3; \(moved) moved")
            let selfMatch = SealGrid.match(codes: try SealGrid.phaseCodes(decoded, phases: [0]), against: marked.record.signature)
            #expect(selfMatch.score == 1 && selfMatch.offsetX == 0 && selfMatch.offsetY == 0)

            let whole = try BurgundySeal.detect(data: marked.png, name: "marked.png", store: store)
            #expect(whole.verdict == .marked && whole.exactBytes && whole.reading.id == marked.record.id && whole.consistent == true)
            #expect(whole.match?.pixelX == 0 && whole.match?.pixelY == 0 && whole.match?.score == 1)
            #expect(whole.reading.reads == 1, "an image marked whole reads at phase (0, 0) first, and once")
            #expect(whole.summary.hasPrefix("Marked · id \(marked.record.id.hex) · recorded as “the composite”"))

            let crop = try MarkFixture.crop(decoded, x: 37, y: 91, w: 1900, h: 900)
            let cropPNG = try PNGEncoding.png(rgb: try MarkFixture.bytes(crop), width: 1900, height: 900)
            let part = try BurgundySeal.detect(data: cropPNG, name: "crop.png", store: store)
            #expect(part.verdict == .marked && !part.exactBytes && part.reading.id == marked.record.id, "\(part.summary)")
            #expect(part.reading.phaseX == 27 && part.reading.phaseY == 5, "the exact phase: the first whole tile starts at (27, 5)")
            #expect(part.match?.pixelX == 37 && part.match?.pixelY == 91)
            #expect(part.consistent == true)
            #expect(part.markMap != nil && part.agreement != nil)
            _ = try BurgundySeal.digest(part)
            _ = try BurgundySeal.overlay(part, query: crop)

            #expect(throws: MarkFailure.alreadyMarked(marked.record.id)) {
                _ = try BurgundySeal.embed(data: marked.png, name: "again.png", store: store)
            }
            let original = try BurgundySeal.detect(data: png, name: "composite.png", store: store)
            #expect(original.reading.id == nil)
        }
    }
}
