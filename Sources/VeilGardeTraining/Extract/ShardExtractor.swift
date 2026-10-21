//
//  ShardExtractor.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Labeled images to one new shard of the features-only store: each image's bytes hashed
//        (the row id, as the store names rows), decoded, measured by FeatureExtractor, and
//        dropped. Nothing but the three columns and the row's metadata is written.
//  PIN:  The id is the SHA-1 of the file's bytes; an id the store already holds is skipped (the
//        store is append-only and an image is measured once). An image that fails to decode is
//        reported, never fatal. The shard is written once, at the end, under a new name, with the
//        extractor's provenance (the DINOv2 variant and its weights' hash) as its metadata.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens

public struct ExtractionItem: Codable, Sendable, Equatable {
    public var path: String
    public var label: Int
    public var category: String
    public var source: String?
    public var golden: Bool?
    public var genFamily: String?

    public init(path: String, label: Int, category: String, source: String? = nil, golden: Bool? = nil, genFamily: String? = nil) {
        self.path = path
        self.label = label
        self.category = category
        self.source = source
        self.golden = golden
        self.genFamily = genFamily
    }

    enum CodingKeys: String, CodingKey {
        case path, label, category, source, golden
        case genFamily = "gen_family"
    }
}

public struct ShardExtraction: Codable, Sendable, Equatable {
    public var shard: String
    public var rows = 0
    public var skippedKnown = 0
    public var failed: [String] = []
    public var seconds = 0.0
}

public enum ShardExtractor {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "heif", "tif", "tiff", "bmp", "gif"]

    /// Images in a folder (not recursive), sorted by name.
    public static func images(in directory: URL) -> [URL] {
        WorkArea.listing(directory).filter { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { directory.appendingPathComponent($0) }
    }

    public static func extract(_ items: [ExtractionItem], shard name: String, store: FeatureStore, extractor: FeatureExtractor,
                               note: (String) -> Void = { _ in }) throws -> ShardExtraction {
        let started = Date()
        var report = ShardExtraction(shard: name)
        if FileManager.default.fileExists(atPath: FeatureShard.metaURL(store.directory, name).path) {
            throw VeilGardeFailure.exists("the store already has a shard named \(name)", hint: "shards are written once; choose a new name")
        }
        var known = (try? store.ids()) ?? []
        LensRuntime.configureGPUMemory()
        defer { LensRuntime.releaseMemory() }
        var rows: [FeatureRow] = []
        var columns: [FeatureColumn: [Float]] = Dictionary(uniqueKeysWithValues: FeatureColumn.allCases.map { ($0, [Float]()) })
        for (k, item) in items.enumerated() {
            let url = URL(fileURLWithPath: (item.path as NSString).expandingTildeInPath)
            do {
                let data = try Data(contentsOf: url)
                let id = ContentHash.sha1Hex(data)
                if known.contains(id) { report.skippedKnown += 1; continue }
                let cg = try ImageDecoding.cgImage(data: data, name: url.lastPathComponent)
                let f = try extractor.extract(cg)
                rows.append(FeatureRow(id: id, path: url.path, label: item.label, category: item.category, source: item.source,
                                       golden: item.golden ?? false, genFamily: item.genFamily, width: f.width, height: f.height))
                for column in FeatureColumn.allCases { columns[column]! += f.values(column) }
                known.insert(id)
            } catch {
                report.failed.append(item.path)
                note("extract: skipped \(item.path): \(error)")
            }
            LensRuntime.releaseMemory()
            if (k + 1) % 50 == 0 { note("extract: \(k + 1) of \(items.count) images") }
        }
        report.rows = rows.count
        if !rows.isEmpty {
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            try FeatureShard(name: name, rows: rows, columns: columns, metadata: extractor.provenance).write(to: store.directory)
        }
        report.seconds = Date().timeIntervalSince(started)
        return report
    }
}
