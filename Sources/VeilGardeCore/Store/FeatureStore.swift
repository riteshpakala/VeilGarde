//
//  FeatureStore.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The features-only store: a directory of shards the flywheel appends to and every trainer
//        reads from. A selection filters rows across shards and stacks the columns asked for,
//        ready for a head, the fusion head or the combiner.
//  PIN:  The Python FS.read semantics: shards in the sorted order of their *_meta.json names, each
//        read whole, filtered, stacked, duplicates kept (the seed store holds 68 ids twice, and the
//        shipped heads were fitted with both copies). `dedup: true` keeps only the first copy of an id,
//        for ingest and the flywheel. Names starting "._" (exFAT sidecars) and subdirectories are
//        ignored.
//

import Foundation

public struct StoreSelection: Sendable {
    public var rows: [FeatureRow]
    /// The shard each row came from.
    public var shards: [String]
    public var columns: [FeatureColumn: [Float]]

    public var count: Int { rows.count }

    public func vector(_ column: FeatureColumn, row index: Int) -> ArraySlice<Float> {
        guard let values = columns[column] else { return [] }
        let w = column.width
        return values[(index * w)..<((index + 1) * w)]
    }

    /// Row-major [count × Σ widths] in the given column order.
    public func matrix(_ order: [FeatureColumn]) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(count * order.reduce(0) { $0 + $1.width })
        for i in 0..<count { for column in order { out.append(contentsOf: vector(column, row: i)) } }
        return out
    }

    /// Rows whose every requested column is finite (the reference trainers drop NaN dino rows the same way).
    public func complete(_ required: [FeatureColumn]) -> StoreSelection {
        let keep = (0..<count).filter { i in required.allSatisfy { column in vector(column, row: i).allSatisfy(\.isFinite) } }
        return subset(keep)
    }

    public func subset(_ indices: [Int]) -> StoreSelection {
        var out = StoreSelection(rows: indices.map { rows[$0] }, shards: indices.map { shards[$0] }, columns: [:])
        for (column, values) in columns {
            let w = column.width
            var picked = [Float]()
            picked.reserveCapacity(indices.count * w)
            for i in indices { picked.append(contentsOf: values[(i * w)..<((i + 1) * w)]) }
            out.columns[column] = picked
        }
        return out
    }

    public func filter(_ isIncluded: (FeatureRow) -> Bool) -> StoreSelection {
        subset((0..<count).filter { isIncluded(rows[$0]) })
    }
}

public struct FeatureStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// Shard names, sorted.
    public func shardNames() -> [String] {
        WorkArea.listing(directory).filter { $0.hasSuffix("_meta.json") }.map { String($0.dropLast("_meta.json".count)) }
            .filter { FileManager.default.fileExists(atPath: FeatureShard.tensorsURL(directory, $0).path) }
    }

    /// Every row of every shard (or of `shards`) that passes `isIncluded`, with `columns` stacked.
    /// With `dedup`, an id already selected from an earlier shard is skipped.
    public func select(columns: Set<FeatureColumn>, shards: [String]? = nil, dedup: Bool = false,
                       where isIncluded: (FeatureRow) -> Bool = { _ in true }) throws -> StoreSelection {
        var selection = StoreSelection(rows: [], shards: [], columns: Dictionary(uniqueKeysWithValues: columns.map { ($0, [Float]()) }))
        var seen = Set<String>()
        for name in shards ?? shardNames() {
            let shard = try FeatureShard.read(name, in: directory, columns: columns)
            for (i, row) in shard.rows.enumerated() where isIncluded(row) && (!dedup || seen.insert(row.id).inserted) {
                selection.rows.append(row)
                selection.shards.append(name)
                for column in columns {
                    if let values = shard.columns[column] {
                        selection.columns[column]!.append(contentsOf: values[(i * column.width)..<((i + 1) * column.width)])
                    } else {
                        selection.columns[column]!.append(contentsOf: [Float](repeating: .nan, count: column.width))
                    }
                }
            }
        }
        return selection
    }

    /// Every row id in the store (for dedup at ingest).
    public func ids() throws -> Set<String> {
        var out = Set<String>()
        for name in shardNames() {
            let rows = try JSONDecoder().decode([FeatureRow].self, from: Data(contentsOf: FeatureShard.metaURL(directory, name)))
            for row in rows { out.insert(row.id) }
        }
        return out
    }
}
