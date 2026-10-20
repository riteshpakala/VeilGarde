//
//  XGBoostScorer.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The tile scorer the detector runs: Frigate's XGBoostTreeModel behind Core's TileScorer,
//        and a cache that parses each model file once per process.
//  PIN:  The only file in the Lens that imports the Frigate umbrella, for FrigateBoost's evaluator;
//        Core's GBDTModel agrees with it bit for bit on the shipped models (ScorerEquivalenceTests).
//

import Foundation
import Frigate

public struct XGBoostScorer: TileScorer {
    public let model: XGBoostTreeModel

    public init(model: XGBoostTreeModel) { self.model = model }

    public var featureCount: Int { model.numFeatures }

    public func scoreBatch(_ rows: [[Float]]) -> [Float] { model.predictBatch(rows) }
}

/// Parsed XGBoost models by path, read-only and shared, so a run of inferences never re-parses
/// a 5 MB model. An entry is keyed by the file's path, modification date and size, so a model the
/// flywheel rewrites in place (a promote, a restore) is parsed again in the same process.
public final class TreeModelCache: @unchecked Sendable {
    public static let shared = TreeModelCache()
    private let lock = NSLock()
    private var cache: [String: (stamp: FileStamp, model: XGBoostTreeModel)] = [:]

    public func model(_ url: URL) throws -> XGBoostTreeModel {
        let key = url.standardizedFileURL.path
        let stamp = FileStamp(path: key)
        lock.lock()
        if let hit = cache[key], hit.stamp == stamp { lock.unlock(); return hit.model }
        lock.unlock()
        let m = try XGBoostTreeModel(url: url)
        lock.lock(); cache[key] = (stamp, m); lock.unlock()
        return m
    }

    public func scorer(_ url: URL) throws -> XGBoostScorer { XGBoostScorer(model: try model(url)) }
}

/// A file's modification date and size: what a cache compares to know a file was rewritten.
public struct FileStamp: Equatable, Sendable {
    public let modified: Date?
    public let size: Int?

    public init(path: String) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        modified = attributes?[.modificationDate] as? Date
        size = (attributes?[.size] as? NSNumber)?.intValue
    }
}
