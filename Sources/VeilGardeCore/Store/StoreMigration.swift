//
//  StoreMigration.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Rewrites a folder of shards of any older format as veilgarde-feature-shard-v1 shards in a
//        new folder: the same rows, and the three columns the store keeps (dino_norm, dino_fusion,
//        cap). Every other tensor an old shard carries (the warp-era tile statistics, the
//        noiseprint, the sharpness) and any side folder are left behind in the old folder, which
//        the migration never writes.
//  PIN:  Refuses before writing anything when a target shard exists. Each shard is checked after it
//        is written: the same row count, and each kept column's tensor bytes with the SHA-256 they
//        had in the old shard. A row key the store no longer reads is dropped by the re-encode.
//

import Foundation

public enum StoreMigration {
    public struct ShardReport: Codable, Sendable, Equatable {
        public var shard: String
        public var rowsIn: Int
        public var rowsOut: Int
        /// Each kept column's tensor SHA-256, the same before and after.
        public var columns: [String: String]
        /// The old shard's tensors the migration left behind.
        public var left: [String]
        public var equal: Bool
    }

    public static func migrate(from source: URL, to target: URL, note: (String) -> Void = { _ in }) throws -> [ShardReport] {
        let fm = FileManager.default
        guard source.standardizedFileURL.path != target.standardizedFileURL.path else {
            throw VeilGardeFailure.usage("the old and new store folders must differ")
        }
        let names = WorkArea.listing(source).filter { $0.hasSuffix("_meta.json") }.map { String($0.dropLast("_meta.json".count)) }
            .filter { fm.fileExists(atPath: FeatureShard.tensorsURL(source, $0).path) }
        guard !names.isEmpty else { throw VeilGardeFailure.missing("no shards in \(source.path)") }
        for name in names where fm.fileExists(atPath: FeatureShard.metaURL(target, name).path) || fm.fileExists(atPath: FeatureShard.tensorsURL(target, name).path) {
            throw VeilGardeFailure.exists("the shard \(name) already exists in \(target.path)", hint: "migrate into an empty folder")
        }
        var reports: [ShardReport] = []
        for (k, name) in names.enumerated() {
            let rows = try FeatureShard.readRows(name, in: source)
            let file = try SafetensorsFile(url: FeatureShard.tensorsURL(source, name))
            var columns: [FeatureColumn: [Float]] = [:]
            var before: [String: String] = [:]
            for column in FeatureColumn.allCases {
                guard let tensor = file.tensors[column.rawValue] else { continue }
                guard tensor.dtype == "F32", tensor.shape == [rows.count, column.width] else {
                    throw VeilGardeFailure.data("\(name).\(column.rawValue) is \(tensor.dtype) \(tensor.shape), not F32 [\(rows.count), \(column.width)]")
                }
                columns[column] = try file.float32(column.rawValue)
                before[column.rawValue] = ContentHash.sha256Hex(try file.bytes(column.rawValue))
            }
            var metadata = file.metadata
            for key in ["format", "rows", "core_version"] { metadata[key] = nil }
            for key in metadata.keys where key.hasPrefix("warp") || key.hasPrefix("noiseprint") || key.hasPrefix("residual") { metadata[key] = nil }
            try FeatureShard(name: name, rows: rows, columns: columns, metadata: metadata).write(to: target)

            let written = try SafetensorsFile(url: FeatureShard.tensorsURL(target, name))
            var after: [String: String] = [:]
            for column in before.keys { after[column] = ContentHash.sha256Hex(try written.bytes(column)) }
            let rowsOut = try FeatureShard.read(name, in: target).count
            let equal = rowsOut == rows.count && after == before
            reports.append(ShardReport(shard: name, rowsIn: rows.count, rowsOut: rowsOut, columns: before,
                                       left: file.names.filter { FeatureColumn(rawValue: $0) == nil }, equal: equal))
            guard equal else { throw VeilGardeFailure.data("the shard \(name) did not migrate whole: rows \(rows.count) → \(rowsOut), columns \(before == after ? "equal" : "changed")") }
            if (k + 1) % 10 == 0 { note("migrate: \(k + 1) of \(names.count) shards") }
        }
        return reports
    }
}
