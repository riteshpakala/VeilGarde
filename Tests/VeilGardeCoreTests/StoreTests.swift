//
//  StoreTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The features-only store: a v1 shard round-trips its rows and columns and is never
//        overwritten; a shard of an older format is refused with the migrate hint, and the
//        migration rewrites it whole (the same rows, the three columns' bytes, the rest left
//        behind); a selection filters, keeps or drops duplicates, and stacks the camera row.
//

import Foundation
import Testing
@testable import VeilGardeCore

@Suite("Feature store")
struct StoreTests {
    func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vg-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func shard(_ name: String, ids: [String], label: Int) -> FeatureShard {
        let rows = ids.map { FeatureRow(id: $0, path: "/x/\($0).jpg", label: label, category: "art", source: "test") }
        var columns: [FeatureColumn: [Float]] = [:]
        for column in FeatureColumn.allCases {
            columns[column] = (0..<(ids.count * column.width)).map { Float($0) + (label == 1 ? 0.5 : 0) }
        }
        return FeatureShard(name: name, rows: rows, columns: columns, metadata: ["dino_variant": "small"])
    }

    @Test("a shard round-trips and is never overwritten")
    func roundTrip() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let written = shard("s1", ids: ["a", "b", "c"], label: 1)
        try written.write(to: dir)
        let read = try FeatureShard.read("s1", in: dir)
        #expect(read.rows == written.rows)
        #expect(read.columns == written.columns)
        #expect(read.metadata["format"] == FeatureShard.format && read.metadata["dino_variant"] == "small")
        #expect(Array(read.vector(.cap, row: 1)) == (9..<18).map { Float($0) + 0.5 })
        #expect(throws: VeilGardeFailure.self) { try written.write(to: dir) }
    }

    @Test("a selection keeps duplicates as the Python store does, dedups on request, filters, and stacks the camera row")
    func selection() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try shard("a_first", ids: ["x", "y"], label: 1).write(to: dir)
        try shard("b_second", ids: ["y", "z"], label: 0).write(to: dir)
        let store = FeatureStore(directory: dir)
        #expect(store.shardNames() == ["a_first", "b_second"])
        #expect(try store.select(columns: [.cap]).rows.map(\.id) == ["x", "y", "y", "z"])
        let all = try store.select(columns: Set(FeatureColumn.allCases), dedup: true)
        #expect(all.rows.map(\.id) == ["x", "y", "z"])
        #expect(all.shards == ["a_first", "a_first", "b_second"])
        let camera = all.matrix(CameraRow.columns)
        #expect(camera.count == 3 * 393)
        #expect(camera[0] == 0.5)                 // x's first dino_fusion value
        #expect(camera[384] == 0.5)               // x's first capture value
        #expect(camera[393 * 2] == 384)           // z's first dino_fusion value (row 1 of b_second)
        let reals = all.filter { !$0.isGenerated }
        #expect(reals.rows.map(\.id) == ["z"])
        #expect(try store.ids() == ["x", "y", "z"])
    }

    @Test("the work area's store reads as v1 shards", .enabled(if: FileManager.default.fileExists(atPath: Fixture.seedStore.appendingPathComponent("ai_video_0711_meta.json").path)))
    func readsSeedStore() throws {
        let shard = try FeatureShard.read("ai_video_0711", in: Fixture.seedStore)
        #expect(shard.count == 112)
        #expect(shard.columns[.dinoNorm]?.count == 112 * 384)
        #expect(shard.columns[.cap]?.count == 112 * 9)
        #expect(shard.rows.allSatisfy { $0.label == 1 && $0.id.count == 40 })
        #expect(shard.metadata["format"] == FeatureShard.format)
    }

    /// A shard as the seed store and the older format wrote it: no format in the header, the
    /// retired tensors beside the kept ones, a row key the store no longer reads.
    func olderShard(_ dir: URL, name: String = "old") throws -> FeatureShard {
        let rows = [FeatureRow(id: "a", path: "/a.jpg", label: 1, category: "art", source: "s"), FeatureRow(id: "b", path: "/b.jpg", label: 0, category: "photo", source: "s")]
        var meta = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows)) as! [[String: Any]]
        meta[0]["warp_model"] = "516119c92d36"
        try JSONSerialization.data(withJSONObject: meta).write(to: FeatureShard.metaURL(dir, name))
        var entries: [SafetensorsWriter.Entry] = []
        var columns: [FeatureColumn: [Float]] = [:]
        for column in FeatureColumn.allCases {
            let values = (0..<(2 * column.width)).map { Float($0) * 0.25 }
            columns[column] = values
            entries.append(.init(column.rawValue, shape: [2, column.width], .float32(values)))
        }
        entries.append(.init("warp", shape: [2, 4], .float32([1, 2, 3, 4, 5, 6, 7, 8])))
        entries.append(.init("noiseprint", shape: [2, 2], .float32([1, 2, 3, 4])))
        try SafetensorsWriter.write(entries, to: FeatureShard.tensorsURL(dir, name))
        return FeatureShard(name: name, rows: rows, columns: columns)
    }

    @Test("a shard of an older format is refused with the migrate hint")
    func olderRefused() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try olderShard(dir)
        #expect(throws: VeilGardeFailure.self) { try FeatureShard.read("old", in: dir) }
        do { _ = try FeatureShard.read("old", in: dir) } catch let failure as VeilGardeFailure {
            #expect(failure.description.contains("store migrate"))
        }
    }

    @Test("the migration rewrites a shard whole: the same rows, the three columns' bytes, the rest left behind; it never overwrites")
    func migration() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("old", isDirectory: true), new = dir.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let expected = try olderShard(old)
        let reports = try StoreMigration.migrate(from: old, to: new)
        #expect(reports.count == 1 && reports[0].equal && reports[0].rowsIn == 2 && reports[0].rowsOut == 2)
        #expect(Set(reports[0].left) == ["noiseprint", "warp"] && reports[0].columns.count == 3)
        let read = try FeatureShard.read("old", in: new)
        #expect(read.rows == expected.rows && read.columns == expected.columns && read.metadata["format"] == FeatureShard.format)
        let meta = try String(contentsOf: FeatureShard.metaURL(new, "old"), encoding: .utf8)
        #expect(!meta.contains("warp_model"), "a row key the store no longer reads is not written back")
        #expect(throws: VeilGardeFailure.self) { try StoreMigration.migrate(from: old, to: new) }
    }
}
