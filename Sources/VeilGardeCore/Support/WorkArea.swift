//
//  WorkArea.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Where VeilGarde's data lives: the folder `VEILGARDE_WORK_AREA` (or `--work-area`) names,
//        and nowhere else: VeilGarde writes no data it was not told where to put. The labelled
//        datasets live under `VEILGARDE_DATASETS`, else the work area's datasets/.
//  OUT:  The layout under the work area: weights/, live/ (the bundle the detector and the flywheel
//        read; .history/ holds the rollback snapshots), store/ (shards/, tiles/, tokens/, the
//        features-only store and its caches), datasets/, candidates/<recipe>/, staged/<date>/,
//        battery/, acquire/, runs/, locks/, and parity/ (the reference fixtures too large for the
//        repo, which the parity tests read).
//  PIN:  A work area may sit on an exFAT drive: no hard links, and macOS writes `._*` sidecars
//        there, so every listing under the work area skips names that start with "._".
//

import Foundation

public struct WorkArea: Sendable, Equatable {
    public static let environmentKey = "VEILGARDE_WORK_AREA"
    public static let datasetsKey = "VEILGARDE_DATASETS"

    public var root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    /// The work area the environment names; nil when it names none.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> WorkArea? {
        guard let named = environment[environmentKey], !named.isEmpty else { return nil }
        return WorkArea(root: URL(fileURLWithPath: (named as NSString).expandingTildeInPath, isDirectory: true))
    }

    /// Where the labelled datasets live (final_mixed and the noiseprint's families): VEILGARDE_DATASETS, else the work
    /// area's datasets/; nil when neither is named.
    public static func datasets(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let named = environment[datasetsKey], !named.isEmpty {
            return URL(fileURLWithPath: (named as NSString).expandingTildeInPath, isDirectory: true)
        }
        return resolve(environment: environment)?.datasets
    }

    public var weights: URL { root.appendingPathComponent("weights", isDirectory: true) }
    public var live: URL { root.appendingPathComponent("live", isDirectory: true) }
    public var liveHistory: URL { live.appendingPathComponent(".history", isDirectory: true) }
    public var store: URL { root.appendingPathComponent("store", isDirectory: true) }
    public var shards: URL { store.appendingPathComponent("shards", isDirectory: true) }
    public var tiles: URL { store.appendingPathComponent("tiles", isDirectory: true) }
    public var tokens: URL { store.appendingPathComponent("tokens", isDirectory: true) }
    public var datasets: URL { root.appendingPathComponent("datasets", isDirectory: true) }
    public var candidates: URL { root.appendingPathComponent("candidates", isDirectory: true) }
    public var staged: URL { root.appendingPathComponent("staged", isDirectory: true) }
    public var battery: URL { root.appendingPathComponent("battery", isDirectory: true) }
    public var acquire: URL { root.appendingPathComponent("acquire", isDirectory: true) }
    public var runs: URL { root.appendingPathComponent("runs", isDirectory: true) }
    public var locks: URL { root.appendingPathComponent("locks", isDirectory: true) }
    public var parity: URL { root.appendingPathComponent("parity", isDirectory: true) }

    public func candidate(_ recipe: String) -> URL { candidates.appendingPathComponent(recipe, isDirectory: true) }

    /// Creates the directories a fresh work area needs (idempotent).
    public func prepare() throws {
        for directory in [weights, live, store, shards, tiles, datasets, candidates, staged, battery, acquire, runs, locks] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// The names in `directory`, sorted, without the exFAT `._*` sidecars and `.DS_Store`.
    public static func listing(_ directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { !$0.hasPrefix("._") && $0 != ".DS_Store" }.sorted()
    }

    /// Free bytes on the volume holding the work area (the nearest existing ancestor).
    public func freeBytes() -> Int64? {
        var url = root
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
