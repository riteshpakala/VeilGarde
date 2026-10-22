//
//  TreeModelCache.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Frigate's XGBoostTreeModel, the evaluator the detector scores the camera head with, parsed
//        once per file and shared.
//  PIN:  The only file in the Lens that imports the Frigate umbrella, for FrigateBoost's evaluator;
//        Core's GBDTModel agrees with it bit for bit on the shipped camera head (ScorerTests).
//

import Foundation
import Frigate

/// Parsed XGBoost models by path, read-only and shared, so a run of inferences never re-parses
/// a model. An entry is keyed by the file's path, modification date and size, so a model the
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
