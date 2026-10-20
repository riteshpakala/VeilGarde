//
//  SupportTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The support layer's promises: stable JSON bytes, known hash vectors, safetensors that
//        round-trip every dtype and write the same bytes twice, splits that never move, a seeded
//        generator that replays, and the recipe TOML subset.
//

import Foundation
import Testing
@testable import VeilGardeCore

@Suite("Support")
struct SupportTests {
    struct Sample: Codable, Equatable { var b: Int; var a: String; var nan: Double }

    @Test("JSON encodes sorted keys and the same bytes every time")
    func stableJSON() throws {
        let value = Sample(b: 2, a: "x/y", nan: .nan)
        let one = try JSONCoding.line(value)
        #expect(one == #"{"a":"x/y","b":2,"nan":"nan"}"#)
        #expect(try JSONCoding.line(value) == one)
        #expect(JSONCoding.standardized(#"{"v": NaN, "s": "NaN"}"#) == #"{"v": "nan", "s": "NaN"}"#)
    }

    @Test("SHA-256 and SHA-1 match their published vectors")
    func hashes() {
        #expect(ContentHash.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ContentHash.sha1Hex(Data("abc".utf8)) == "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    @Test("safetensors round-trip every dtype and write identical bytes")
    func safetensorsRoundTrip() throws {
        let entries = [
            SafetensorsWriter.Entry("z_f32", shape: [2, 3], .float32([0, 1.5, -2, .infinity, 3e-38, 7])),
            SafetensorsWriter.Entry("a_i32", shape: [3], .int32([-1, 0, Int32.max])),
            SafetensorsWriter.Entry("m_i16", shape: [2], .int16([-7, 300])),
            SafetensorsWriter.Entry("u_u8", shape: [4], .uint8([0, 1, 254, 255])),
            SafetensorsWriter.Entry("h_f16", shape: [2], .float16Bits([0x3C00, 0xC000])),
        ]
        let data = try SafetensorsWriter.encode(entries, metadata: ["format": "test-v1", "b": "2"])
        #expect(try SafetensorsWriter.encode(entries.reversed(), metadata: ["b": "2", "format": "test-v1"]) == data)
        let file = try SafetensorsFile(data: data)
        #expect(file.metadata == ["format": "test-v1", "b": "2"])
        #expect(try file.float32("z_f32") == [0, 1.5, -2, .infinity, 3e-38, 7])
        #expect(try file.tensor("z_f32").shape == [2, 3])
        #expect(try file.int32("a_i32") == [-1, 0, Int32.max])
        #expect(try file.int16("m_i16") == [-7, 300])
        #expect(try file.uint8("u_u8") == [0, 1, 254, 255])
        #expect(try file.float32("h_f16") == [1, -2])
        let headerLength = data.withUnsafeBytes { Int(UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
        #expect((8 + headerLength) % 8 == 0)
    }

    @Test("a split assignment never moves and its fractions hold")
    func stableSplit() {
        #expect(StableSplit.unit("IMG_0291", salt: "split:v1") == StableSplit.unit("IMG_0291", salt: "split:v1"))
        #expect(StableSplit.unit("IMG_0291", salt: "split:v1") != StableSplit.unit("IMG_0291", salt: "platt:v1"))
        var counts: [Partition: Int] = [:]
        for i in 0..<10_000 { counts[StableSplit.partition("stem-\(i)", salt: "split:v1", train: 0.70, val: 0.15), default: 0] += 1 }
        #expect(abs(Double(counts[.train] ?? 0) / 10_000 - 0.70) < 0.02)
        #expect(abs(Double(counts[.val] ?? 0) / 10_000 - 0.15) < 0.02)
    }

    @Test("SplitMix64 replays its sequence and shuffles every index once")
    func splitMix() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        #expect((0..<8).map { _ in a.next() } == (0..<8).map { _ in b.next() })
        var c = SplitMix64(seed: 7)
        #expect(Set(c.permutation(100)) == Set(0..<100))
        var d = SplitMix64(seed: 1)
        #expect((0..<1000).allSatisfy { _ in (0..<1).contains(d.unit()) })
    }

    @Test("the recipe TOML subset parses tables, values and comments")
    func toml() throws {
        let document = try TOMLSubset.parse("""
        id = "shipped" # the recipe
        [warp]
        trees = 200
        eta = 0.05
        heads = ["art", "blur"]
        """)
        #expect(TOMLSubset.value(document, "", "id")?.string == "shipped")
        #expect(TOMLSubset.value(document, "warp", "trees")?.integer == 200)
        #expect(TOMLSubset.value(document, "warp", "eta")?.float == 0.05)
        #expect(TOMLSubset.value(document, "warp", "heads")?.strings == ["art", "blur"])
    }

    @Test("the work area is the one the environment names, else none; the datasets theirs, else the work area's")
    func workArea() {
        #expect(WorkArea.resolve(environment: ["VEILGARDE_WORK_AREA": "/tmp/vg-area"])?.root.path == "/tmp/vg-area")
        #expect(WorkArea.resolve(environment: [:]) == nil && WorkArea.resolve(environment: ["VEILGARDE_WORK_AREA": ""]) == nil)
        #expect(WorkArea.datasets(environment: ["VEILGARDE_WORK_AREA": "/tmp/vg-area"])?.path == "/tmp/vg-area/datasets")
        #expect(WorkArea.datasets(environment: ["VEILGARDE_WORK_AREA": "/tmp/vg-area", "VEILGARDE_DATASETS": "/data"])?.path == "/data")
        #expect(WorkArea.datasets(environment: [:]) == nil)
    }
}
