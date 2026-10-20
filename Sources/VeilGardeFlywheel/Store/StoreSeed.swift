//
//  StoreSeed.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The work area's store seeded from an existing feature store: every shard copied as it
//        was written, so the flywheel trains on the 138,247 rows the shipped heads were
//        fitted on and every row it adds lands beside them.
//  PIN:  Read-only on the source. A shard whose name already exists in the destination is left
//        alone (shards are written once); subdirectories and "._" sidecars are skipped. Each copy
//        is re-read and its row count checked against the source's meta list.
//

import Foundation
import VeilGardeCore

public struct StoreSeedReport: Codable, Sendable, Equatable {
    public var copied: [String] = []
    public var kept: [String] = []
    public var rows = 0
    public var bytes = 0
}

public enum StoreSeed {
    public static func copy(from source: URL, to destination: URL, note: (String) -> Void = { _ in }) throws -> StoreSeedReport {
        let fm = FileManager.default
        let from = FeatureStore(directory: source)
        let names = from.shardNames()
        guard !names.isEmpty else { throw VeilGardeFailure.missing("no shards in \(source.path)") }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var report = StoreSeedReport()
        for name in names {
            let meta = FeatureShard.metaURL(destination, name), tensors = FeatureShard.tensorsURL(destination, name)
            if fm.fileExists(atPath: meta.path) || fm.fileExists(atPath: tensors.path) { report.kept.append(name); continue }
            let sourceRows = try JSONDecoder().decode([FeatureRow].self, from: Data(contentsOf: FeatureShard.metaURL(source, name))).count
            try fm.copyItem(at: FeatureShard.tensorsURL(source, name), to: tensors)
            try fm.copyItem(at: FeatureShard.metaURL(source, name), to: meta)
            let copied = try FeatureShard.read(name, in: destination)
            guard copied.count == sourceRows else { throw VeilGardeFailure.data("shard \(name) copied with \(copied.count) rows, the source has \(sourceRows)") }
            report.copied.append(name)
            report.rows += copied.count
            report.bytes += ((try? fm.attributesOfItem(atPath: tensors.path)[.size] as? NSNumber)?.intValue ?? 0)
            note("seed: \(name) (\(copied.count) rows)")
        }
        return report
    }
}
