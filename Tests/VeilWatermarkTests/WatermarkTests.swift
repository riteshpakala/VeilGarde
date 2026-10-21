//
//  WatermarkTests.swift
//  VeilWatermarkTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: VeilWatermark v1's mechanics: tile codes and their edge masks, section packing, every
//        serialization (binary, vw1 text, JSON, the content id), and the matcher on synthetic
//        grids; then, on the GPU, that signing is deterministic, that an image matches itself
//        at offset 0 with score 1, and that a tile-aligned crop matches at its exact offset.
//        Whether v1 survives real crops and re-encodes is the acceptance run's question
//        (`veilgarde watermark accept`), not these tests'.
//

import CoreGraphics
import Foundation
import Testing
import VeilGardeCore
@testable import VeilWatermark

func randomCodes(rows: Int, cols: Int, seed: UInt64) -> TileCodeGrid {
    var rng = SplitMix64(seed: seed)
    var values = [Float](repeating: 0, count: rows * cols)
    for i in values.indices { values[i] = Float(rng.unit()) }
    return TileCodeGrid(FragilityGrid(rows: rows, cols: cols, values: values))
}

@Suite("Watermark mechanics")
struct WatermarkTests {
    @Test("tile codes: four ordinal bits against E, S, SE, NE, masked at the edges")
    func codes() {
        // 2 × 3:  1 5 2
        //         4 3 6
        let g = TileCodeGrid(FragilityGrid(rows: 2, cols: 3, values: [1, 5, 2, 4, 3, 6]))
        // Tile (0,0)=1: E 5 no, S 4 no, SE 3 no, NE outside.
        #expect(g.bits[0] == 0 && g.masks[0] == 0b0111)
        // Tile (0,1)=5: E 2 yes, S 3 yes, SE 6 no, NE outside.
        #expect(g.bits[1] == 0b0011 && g.masks[1] == 0b0111)
        // Tile (0,2)=2: only S (6) is inside: no.
        #expect(g.bits[2] == 0 && g.masks[2] == 0b0010)
        // Tile (1,0)=4: E 3 yes, S and SE outside, NE 5 no.
        #expect(g.bits[3] == 0b0001 && g.masks[3] == 0b1001)
        // Tile (1,2)=6: nothing forward is inside.
        #expect(g.masks[5] == 0)
        #expect(g.measuredBits == 3 + 3 + 1 + 2 + 2 + 0)
    }

    @Test("sections pack sixteen nibbles a word and unpack exactly, borders masked")
    func sections() {
        for (r, c) in [(1, 1), (4, 4), (7, 9), (13, 5)] {
            let g = randomCodes(rows: r, cols: c, seed: UInt64(r * 100 + c))
            let (codes, masks) = Sectioning.pack(g)
            #expect(codes.count == Sectioning.sectionRows(r) * Sectioning.sectionCols(c))
            #expect(Sectioning.unpack(codes: codes, masks: masks, rows: r, cols: c) == g)
        }
    }

    @Test("a signature round-trips through binary, vw1 text and JSON, and its cid is its bytes'")
    func serialization() throws {
        let sig = WatermarkSignature(grid: randomCodes(rows: 11, cols: 17, seed: 9))
        #expect(try WatermarkSignature(binary: sig.binary) == sig)
        #expect(sig.compact.hasPrefix("vw1:") && !sig.compact.contains("=") && !sig.compact.contains("+"))
        #expect(try WatermarkSignature(compact: sig.compact) == sig)
        let json = try JSONCoding.prettyEncoder().encode(sig)
        #expect(try JSONDecoder().decode(WatermarkSignature.self, from: json) == sig)
        #expect(sig.cid == ContentHash.sha256Hex(sig.binary) && sig.cid.count == 64)
        #expect(sig.tileCodes == randomCodes(rows: 11, cols: 17, seed: 9))
        var tampered = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        var words = tampered["codes"] as! [String]
        words[0] = String(format: "%016llx", (UInt64(words[0], radix: 16)! ^ 1))
        tampered["codes"] = words
        #expect(throws: VeilGardeFailure.self) { try JSONDecoder().decode(WatermarkSignature.self, from: try JSONSerialization.data(withJSONObject: tampered)) }
        #expect(throws: VeilGardeFailure.self) { try WatermarkSignature(binary: Data("VW2\0".utf8) + sig.binary.dropFirst(4)) }
        #expect(throws: VeilGardeFailure.self) { try WatermarkSignature(binary: sig.binary.dropLast(8)) }
    }

    @Test("the matcher finds a sub-grid's offset, tolerates flipped bits, and scores a stranger at chance")
    func matcher() throws {
        let stored = randomCodes(rows: 24, cols: 30, seed: 1)
        func cut(_ g: TileCodeGrid, r0: Int, c0: Int, rows: Int, cols: Int, flip: Double = 0, seed: UInt64 = 0) -> TileCodeGrid {
            var rng = SplitMix64(seed: seed)
            var bits: [UInt8] = [], masks: [UInt8] = []
            for r in r0..<(r0 + rows) {
                for c in c0..<(c0 + cols) {
                    var b = g.bits[r * g.cols + c]
                    for k in 0..<4 where rng.unit() < flip { b ^= 1 << k }
                    bits.append(b)
                    // The crop's own edge: its last row and column cannot compare forward.
                    var m = g.masks[r * g.cols + c]
                    if r == r0 + rows - 1 { m &= ~(0b0110) }
                    if c == c0 + cols - 1 { m &= ~(0b1101) }
                    if r == r0 { m &= ~(0b1000) }
                    masks.append(m)
                }
            }
            return TileCodeGrid(rows: rows, cols: cols, bits: bits, masks: masks)
        }
        let exact = try #require(Matcher.best(crop: cut(stored, r0: 5, c0: 7, rows: 12, cols: 14), stored: stored, minimumBits: 256))
        #expect(exact.dx == 7 && exact.dy == 5 && exact.score == 1)
        let noisy = try #require(Matcher.best(crop: cut(stored, r0: 9, c0: 3, rows: 12, cols: 14, flip: 0.1, seed: 4), stored: stored, minimumBits: 256))
        #expect(noisy.dx == 3 && noisy.dy == 9 && abs(noisy.score - 0.9) < 0.05)
        let stranger = try #require(Matcher.best(crop: randomCodes(rows: 12, cols: 14, seed: 77), stored: stored, minimumBits: 256))
        #expect(stranger.score < 0.62, "the best of many chance alignments stays near 0.5: \(stranger.score)")
        #expect(Matcher.best(crop: randomCodes(rows: 3, cols: 3, seed: 5), stored: stored, minimumBits: 256) == nil, "too few bits to judge")
        #expect(abs(Matcher.zScore(score: 0.75, bits: 400) - 10) < 1e-9)
    }
}

@Suite("The acceptance's sample")
struct AcceptanceSampleTests {
    func dataset(_ csv: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vg-fm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try csv.write(to: dir.appendingPathComponent("manifest.csv"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test("final_mixed's CSV reads in file order, quotes and all")
    func finalMixed() throws {
        let dir = try dataset("dest_name,class,source_pool,tag,scored_verdict,src_path\r\niphone_real_00000.jpeg,real,iphone,iphone,real,\"/a,b/IMG.jpeg\"\r\nagvr_ai_00001.png,generated,agvr_gen,fill,generated,/x.png\r\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = try AcceptanceSample.dataset(dir)
        #expect(items.map(\.url.lastPathComponent) == ["iphone_real_00000.jpeg", "agvr_ai_00001.png"])
        #expect(items.map { $0.url.deletingLastPathComponent().lastPathComponent } == ["real", "generated"])
        #expect(items.map(\.label) == [0, 1])
    }

    @Test("the sample is seeded, at most n of each label, in the dataset's order")
    func sample() {
        let items = (0..<200).map { AcceptanceSample.Item(url: URL(fileURLWithPath: "/d/\($0).jpg"), label: $0 % 3 == 0 ? 1 : 0) }
        let a = AcceptanceSample.sample(items, perLabel: 10, seed: 0)
        #expect(a.count == 20 && a.filter { $0.label == 1 }.count == 10)
        #expect(a == AcceptanceSample.sample(items, perLabel: 10, seed: 0))
        #expect(a != AcceptanceSample.sample(items, perLabel: 10, seed: 1))
        let order = a.map { Int($0.url.deletingPathExtension().lastPathComponent)! }
        #expect(order == order.sorted(), "kept rows stay in the dataset's order")
    }
}

extension WatermarkMLXSuites {
    @Suite("Watermark on the GPU", .serialized)
    struct OnGPU {
        static let image = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VeilGardeInferenceTests/Fixtures/crops/crop_ben.png")

        @Test("signing is deterministic, an image matches itself, a tile-aligned crop matches at its offset")
        func signAndMatch() throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Self.image)
            let a = try Watermark.sign(cg), b = try Watermark.sign(cg)
            #expect(a == b && a.cid == b.cid)
            #expect(a.rows == 16 && a.cols == 16)
            let me = try Watermark.match(cg, against: a, options: MatchOptions(phases: [0]))
            #expect(me.matched && me.score == 1 && me.offsetX == 0 && me.offsetY == 0)
            let crop = try #require(ImageLoading.renderCrop(cg, CGRect(x: 96, y: 160, width: 320, height: 288)))
            let r = try Watermark.match(crop, against: a, options: MatchOptions(phases: [0]))
            #expect(r.matched && r.score == 1 && r.offsetX == 3 && r.offsetY == 5 && r.pixelX == 96 && r.pixelY == 160)
            let full = try Watermark.match(crop, against: a)
            #expect(full.score == 1 && full.phaseX == 0 && full.phaseY == 0, "the full phase search finds the aligned phase")
        }

        @Test("flattening to the lens's 8-bit bitmap leaves the signature unchanged; a JPEG of it still matches")
        func flattened() throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Self.image)
            let flat = try #require(ImageCodec.flattened(cg))
            #expect(ImageCodec.isFlat(flat))
            #expect(try Watermark.sign(flat) == Watermark.sign(cg))
            let jpeg = try ImageCodec.recompressed(flat, as: .jpeg, quality: 0.75)
            let r = try Watermark.match(jpeg, against: try Watermark.sign(cg), options: MatchOptions(phases: [0]))
            #expect(r.offsetX == 0 && r.offsetY == 0 && r.score > 0.75, "JPEG 0.75 scored \(r.score)")
        }
    }
}

@Suite("Watermark invariance")
struct WatermarkInvarianceTests {
    static func row(_ path: String, cid: String = "c1", bits: Int = 930) -> InvarianceRow {
        InvarianceRow(path: path, fileSHA256: "f-\(path)", width: 512, height: 512, rows: 16, cols: 16, sections: 16, measuredBits: bits, cid: cid,
                      compactSHA256: "k-\(cid)", seconds: 1)
    }

    @Test("equal reports have no difference; a moved signature, a lost image and a new one each show")
    func compare() {
        let baseline = InvarianceReport(date: Date(), coreVersion: "x", images: [Self.row("/a.png"), Self.row("/b.png")], skipped: [])
        #expect(WatermarkInvariance.compare(baseline: baseline, current: baseline).isEmpty)
        let moved = InvarianceReport(date: Date(), coreVersion: "x", images: [Self.row("/a.png", cid: "c2", bits: 929), Self.row("/c.png")], skipped: ["/b.png: gone"])
        let d = WatermarkInvariance.compare(baseline: baseline, current: moved)
        #expect(Set(d.map(\.field)) == ["cid", "compactSHA256", "measuredBits", "signed"])
        #expect(d.contains { $0.path == "/b.png" && $0.current == "no" } && d.contains { $0.path == "/c.png" && $0.baseline == "absent" })
    }
}
