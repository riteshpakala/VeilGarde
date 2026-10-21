//
//  StoreTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The features-only store: a shard round-trips its rows and columns, is never overwritten,
//        reads the seed store's shards as they were written (their retired columns and row keys
//        ignored), and a selection filters, keeps or drops duplicates, and stacks the fusion row.
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

    @Test("a selection keeps duplicates as the Python store does, dedups on request, filters, and stacks the fusion columns")
    func selection() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try shard("a_first", ids: ["x", "y"], label: 1).write(to: dir)
        try shard("b_second", ids: ["y", "z"], label: 0).write(to: dir)
        let store = FeatureStore(directory: dir)
        #expect(store.shardNames() == ["a_first", "b_second"])
        #expect(try store.select(columns: [.cap]).rows.map(\.id) == ["x", "y", "y", "z"])
        let all = try store.select(columns: Set(FusionLayout.bothReadings.columns), dedup: true)
        #expect(all.rows.map(\.id) == ["x", "y", "z"])
        #expect(all.shards == ["a_first", "a_first", "b_second"])
        let fusion = all.matrix(FusionLayout.dinoCapture.columns)
        #expect(fusion.count == 3 * 393 && all.matrix(FusionLayout.bothReadings.columns).count == 3 * 777)
        #expect(fusion[0] == 0.5)                 // x's first dino_fusion value
        #expect(fusion[384] == 0.5)               // x's first capture value
        #expect(fusion[393 * 2] == 384)           // z's first dino_fusion value (row 1 of b_second)
        let reals = all.filter { !$0.isGenerated }
        #expect(reals.rows.map(\.id) == ["z"])
        #expect(try store.ids() == ["x", "y", "z"])
    }

    @Test("the seed store's shards read as they were written", .enabled(if: FileManager.default.fileExists(atPath: Fixture.seedStore.appendingPathComponent("ai_video_0711_meta.json").path)))
    func readsSeedStore() throws {
        let shard = try FeatureShard.read("ai_video_0711", in: Fixture.seedStore)
        #expect(shard.count == 112)
        #expect(shard.columns[.dinoNorm]?.count == 112 * 384)
        #expect(shard.columns[.cap]?.count == 112 * 9)
        #expect(shard.rows.allSatisfy { $0.label == 1 && $0.id.count == 40 })
        #expect(shard.metadata.isEmpty)
    }

    @Test("a row written before 2026-10-21 still decodes, its warp model key ignored")
    func olderRow() throws {
        let json = #"{"id": "a", "path": "/a.jpg", "label": 1, "category": "art", "source": "s", "nsfw": false, "golden": false, "warp_model": "516119c92d36"}"#
        let row = try JSONDecoder().decode(FeatureRow.self, from: Data(json.utf8))
        #expect(row.id == "a" && row.isGenerated)
    }

    @Test("a column measured later lives in a side file bound to its shard's ids; one bound to other rows is refused")
    func sideColumn() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var old = shard("seed", ids: ["a", "b"], label: 1)
        old.columns[.residual] = nil
        try old.write(to: dir)
        let store = FeatureStore(directory: dir)
        let before = try store.select(columns: [.residual])
        let missing = before.vector(.residual, row: 0).allSatisfy { $0.isNaN }
        #expect(missing, "no side file yet: the column reads as missing")
        let values = (0..<(2 * 38)).map { Float($0) }
        try FeatureShard.writeSide(.residual, values: values, for: "seed", in: dir)
        #expect(throws: VeilGardeFailure.self, "a side file is written once") { try FeatureShard.writeSide(.residual, values: values, for: "seed", in: dir) }
        let after = try store.select(columns: [.residual, .cap])
        #expect(Array(after.vector(.residual, row: 1)) == Array(values[38..<76]) && store.shardNames() == ["seed"])
        // The side file belongs to rows a, b: a shard whose rows changed refuses it.
        var moved = shard("seed", ids: ["a", "c"], label: 1)
        moved.columns[.residual] = nil
        try moved.write(to: dir, replacing: true)
        #expect(throws: VeilGardeFailure.self) { try FeatureShard.read("seed", in: dir, columns: [.residual]) }
    }

    @Test("the residual column is the 19 tile features' mean then spread, and the residual layout reads it after capture")
    func residualColumn() {
        #expect(FeatureColumn.residual.width == 38 && FeatureColumn.residualFeatures.count == 19)
        #expect(FeatureColumn.residualNames.first == "FR_mean" && FeatureColumn.residualNames[19] == "FR_std" && FeatureColumn.residualNames.last == "nyq_R_std")
        #expect(FusionLayout.bothReadingsResidual.width == 815 && FusionLayout.bothReadingsResidual.columns.last == .residual)
        #expect(FusionLayout.bothReadingsResidual.names[777] == "res_FR_mean" && FusionLayout(width: 815) == .bothReadingsResidual)
    }
}
