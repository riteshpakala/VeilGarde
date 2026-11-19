//
//  MarkTests.swift
//  VeilSealTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The Burgundy Seal end to end, on the GPU. A parity crop sealed and found again in itself, a
//        crop, a 2× resize and a JPEG; a stranger found as nothing; sealing it again returns the same
//        seal. An unmarked crop reads no interlace and is too small to carry one. The 2048 × 1024
//        composite sealed with an interlace: the copy stays within L∞ 3 and 40 dB and moves R, G and B
//        together, is found as sealed with its id read from its bytes and from a crop at an odd offset,
//        refuses a second interlace, and the original (no interlace) is still found by its anchors.
//        Whether the seal survives final_mixed's crops, resizes, filters and recaptures is
//        `seal accept`'s question, not these tests'.
//

import CoreGraphics
import Foundation
import Testing
import VeilGardeCore
import VeilGardeLens
@testable import VeilSeal

extension WatermarkMLXSuites {
    @Suite("The Burgundy Seal on the GPU", .serialized)
    struct SealGPU {
        static func store() throws -> (SealStore, URL) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("seal-\(UUID().uuidString)", isDirectory: true)
            return (try SealStore(directory: folder), folder)
        }

        static func png(_ cg: CGImage) throws -> Data { try PNGEncoding.png(rgb: try MarkFixture.bytes(cg), width: cg.width, height: cg.height) }

        @Test("a crop sealed is found in itself, a crop, a 2× resize, JPEG 60 and the other crop of its scene; a stranger is not; sealing again names the same seal")
        func roundTrip() throws {
            let (store, folder) = try Self.store()
            defer { try? FileManager.default.removeItem(at: folder) }
            let sealed = try BurgundySeal.seal(contentsOf: Fixture.crop("crop_fox.png"), label: "the fox", store: store)
            let r = sealed.record
            #expect(!sealed.existing && sealed.interlaced == nil && r.interlace == nil)
            #expect(r.anchors.count >= 120 && r.paths.count >= 30 && r.anchors.allSatisfy { $0.fragility != nil && $0.residual != nil })
            #expect(try store.record(for: r.id) == r)

            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.crop("crop_fox.png"))
            let copies: [(String, CGImage)] = [
                ("itself", cg),
                ("crop", try MarkFixture.crop(cg, x: 120, y: 60, w: 300, h: 320)),
                ("2×", try #require(ImageCodec.resized(cg, by: 2))),
                ("JPEG 60", try ImageCodec.recompressed(cg, as: .jpeg, quality: 0.6)),
            ]
            for (name, copy) in copies {
                let d = try BurgundySeal.detect(copy, store: store)
                #expect(d.verdict == .sealed && d.match?.id == r.id && d.match?.label == "the fox", "\(name): \(d.summary)")
                if name == "2×" { #expect(abs((d.match?.scale ?? 0) - 2) < 0.05, "\(name): scale \(d.match?.scale ?? 0)") }
                if name == "crop" { #expect(abs((d.match?.coverage ?? 0) - 300.0 * 320 / (512 * 512)) < 0.05, "coverage \(d.match?.coverage ?? 0)") }
                if name == "itself" { #expect(d.match?.residualAgreement ?? 0 > 0.95) }
            }
            // crop_ben is the same scene seen wider: the fox's whole picture sits in it at about half size.
            let wider = try BurgundySeal.detect(contentsOf: Fixture.crop("crop_ben.png"), store: store)
            #expect(wider.verdict == .sealed && abs((wider.match?.scale ?? 0) - 0.5) < 0.05, "\(wider.summary)")
            for seed in [UInt64(1), 2, 3] {
                let stranger = try BurgundySeal.detect(try MarkFixture.stranger(seed: seed), store: store)
                #expect(stranger.verdict == .none, "stranger \(seed): \(stranger.summary)")
            }

            let again = try BurgundySeal.seal(contentsOf: Fixture.crop("crop_fox.png"), label: "the fox, again", store: store)
            #expect(again.existing && again.record.id == r.id && again.record.label == "the fox, again")
            #expect(try store.records().count == 1)
            #expect(throws: SealFailure.messageNotYet) {
                _ = try BurgundySeal.seal(contentsOf: Fixture.crop("crop_fox.png"), store: store, interlace: .message("mine"))
            }
        }

        @Test("an unmarked parity crop reads no interlace at any phase, and is too small to carry one", arguments: ["crop_ben.png", "crop_fox.png"])
        func unmarked(name: String) throws {
            let reading = MarkDecoder.read(try NativePlane(try ImageDecoding.cgImage(contentsOf: Fixture.crop(name))))
            #expect(reading.id == nil)
            // Phase (0, 0), every y at x 0 and 16, every x at the three best y's apart: one window, so nothing
            // is read twice.
            #expect(reading.tiles == 225 && reading.reads == 154)
            #expect(throws: SealFailure.tooSmallToInterlace(tiles: 225, needed: MarkDecoder.minimumTiles)) {
                _ = try BurgundySeal.seal(contentsOf: Fixture.crop(name), store: nil, interlace: .signature)
            }
        }

        @Test("the composite sealed with an interlace: bounded, R G B together, found with its id from its bytes and a crop; refused a second interlace")
        func interlaced() throws {
            let (store, folder) = try Self.store()
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = try MarkFixture.composite()
            let png = try Self.png(source)
            var stages: [SealProgress] = []
            let sealed = try BurgundySeal.seal(data: png, name: "composite.png", label: "the composite", store: store, interlace: .signature,
                                               progress: { stages.append($0) })
            let copy = try #require(sealed.interlaced)
            let report = try #require(sealed.record.interlace?.report)
            #expect(report.linf <= 3 && report.psnr >= 40, "L∞ \(report.linf), PSNR \(report.psnr)")
            #expect(report.verified, "satisfied \(report.satisfied), pilot z \(report.pilotZ)")
            #expect(stages.contains(.interlacing) && sealed.record.image.sha256 == ContentHash.sha256Hex(copy))

            let decoded = try ImageDecoding.cgImage(data: copy)
            let before = try MarkFixture.bytes(source), after = try MarkFixture.bytes(decoded)
            var moved = 0, uneven = 0
            for i in 0..<(before.count / 3) {
                let d = (0..<3).map { Int(after[3 * i + $0]) - Int(before[3 * i + $0]) }
                if d[0] != d[1] || d[1] != d[2] || abs(d[0]) > 3 { uneven += 1 }
                if d[0] != 0 { moved += 1 }
            }
            #expect(uneven == 0 && moved > 0, "\(uneven) pixels moved R, G and B apart or past 3; \(moved) moved")

            let whole = try BurgundySeal.detect(data: copy, name: "sealed.png", store: store)
            #expect(whole.verdict == .sealed && whole.interlaced == sealed.record.id && whole.match?.id == sealed.record.id, "\(whole.summary)")
            let crop = try MarkFixture.crop(decoded, x: 37, y: 91, w: 1900, h: 900)
            let part = try BurgundySeal.detect(data: try Self.png(crop), name: "crop.png", store: store)
            #expect(part.verdict == .sealed && part.interlaced == sealed.record.id, "\(part.summary)")

            #expect(throws: SealFailure.alreadyInterlaced(sealed.record.id)) {
                _ = try BurgundySeal.seal(data: copy, name: "again.png", store: store, interlace: .signature)
            }
            let original = try BurgundySeal.detect(data: png, name: "composite.png", store: store)
            #expect(original.interlaced == nil && original.verdict == .sealed, "\(original.summary)")
        }
    }
}
