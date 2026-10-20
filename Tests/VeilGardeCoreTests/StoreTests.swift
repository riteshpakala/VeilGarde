//
//  StoreTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The features-only store: a shard round-trips its rows and columns, is never overwritten,
//        reads the seed store's shards as they were written, and a selection filters, keeps or drops duplicates, and stacks.
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
        let rows = ids.map { FeatureRow(id: $0, path: "/x/\($0).jpg", label: label, category: "art", source: "test", warpModel: "516119c92d36") }
        var columns: [FeatureColumn: [Float]] = [:]
        for column in FeatureColumn.allCases {
            columns[column] = (0..<(ids.count * column.width)).map { Float($0) + (label == 1 ? 0.5 : 0) }
        }
        return FeatureShard(name: name, rows: rows, columns: columns, metadata: ["warp_model_sha256": "516119c9"])
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
        #expect(read.metadata["format"] == FeatureShard.format && read.metadata["warp_model_sha256"] == "516119c9")
        #expect(Array(read.vector(.cap, row: 1)) == (9..<18).map { Float($0) + 0.5 })
        #expect(throws: VeilGardeFailure.self) { try written.write(to: dir) }
    }

    @Test("a selection keeps duplicates as the Python store does, dedups on request, filters, and stacks the fusion columns")
    func selection() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try shard("a_first", ids: ["x", "y"], label: 1).write(to: dir)
        try shard("b_second", ids: ["y", "z"], label: 0).write(to: dir)
        let store = FeatureStore(directory: dir)
        #expect(store.shardNames() == ["a_first", "b_second"])
        #expect(try store.select(columns: [.warp]).rows.map(\.id) == ["x", "y", "y", "z"])
        let all = try store.select(columns: Set(FeatureColumn.fusion), dedup: true)
        #expect(all.rows.map(\.id) == ["x", "y", "z"])
        #expect(all.shards == ["a_first", "a_first", "b_second"])
        let fusion = all.matrix(FeatureColumn.fusion)
        #expect(fusion.count == 3 * 397)
        #expect(fusion[0] == 0.5)                 // x's warp
        #expect(fusion[397 * 2] == 1)             // z's warp (row 1 of b_second)
        let reals = all.filter { !$0.isGenerated }
        #expect(reals.rows.map(\.id) == ["z"])
        #expect(try store.ids() == ["x", "y", "z"])
    }

    @Test("the seed store's shards read as they were written", .enabled(if: FileManager.default.fileExists(atPath: Fixture.seedStore.appendingPathComponent("ai_video_0711_meta.json").path)))
    func readsRa() throws {
        let shard = try FeatureShard.read("ai_video_0711", in: Fixture.seedStore)
        #expect(shard.count == 112)
        #expect(shard.columns[.dinoNorm]?.count == 112 * 384)
        #expect(shard.columns[.cap]?.count == 112 * 9)
        #expect(shard.rows.allSatisfy { $0.label == 1 && $0.id.count == 40 })
        #expect(shard.metadata.isEmpty)
    }
}
