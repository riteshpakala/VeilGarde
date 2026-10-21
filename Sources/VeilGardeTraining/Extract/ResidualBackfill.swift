//
//  ResidualBackfill.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The store's residual column for shards written before it existed: every row whose image
//        is still at its recorded path is read, checked against the row's id (the SHA-1 of its
//        bytes), measured by the watermark's ResidualStatistics and dropped. Each shard gets a side
//        file, NaN where the image is gone, its bytes changed, or it would not decode.
//  PIN:  Store features, not images: nothing here writes an image. Decoding runs on CPU threads a
//        batch ahead of the GPU; the measurement runs one image at a time. A shard whose side file
//        exists is skipped unless replacing, so a stopped run resumes where it stopped.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens
import VeilWatermark

public enum ResidualBackfill {
    public struct ShardReport: Codable, Sendable, Equatable {
        public var shard: String
        public var rows: Int
        public var measured: Int
        /// The image is no longer at its recorded path.
        public var missing: Int
        /// The file there is not the row's bytes.
        public var mismatched: Int
        public var failed: Int
        public var skipped: Bool
        public var seconds: Double
    }

    /// Fills `shards` (default: every shard) of the store at `store`.
    public static func run(store: URL, shards: [String]? = nil, replacing: Bool = false, batch: Int = 16,
                           note: (String) -> Void = { _ in }) throws -> [ShardReport] {
        let fs = FeatureStore(directory: store)
        var reports: [ShardReport] = []
        let names = shards ?? fs.shardNames()
        for (s, name) in names.enumerated() {
            let started = Date()
            let rows = try JSONDecoder().decode([FeatureRow].self, from: Data(contentsOf: FeatureShard.metaURL(store, name)))
            if !replacing, FileManager.default.fileExists(atPath: FeatureShard.sideURL(store, .residual, name).path) {
                reports.append(ShardReport(shard: name, rows: rows.count, measured: 0, missing: 0, mismatched: 0, failed: 0, skipped: true, seconds: 0))
                continue
            }
            let width = FeatureColumn.residual.width
            var values = [Float](repeating: .nan, count: rows.count * width)
            var measured = 0, missing = 0, mismatched = 0, failed = 0
            var start = 0
            while start < rows.count {
                let end = min(start + batch, rows.count)
                // CPU: read, check and decode the batch on threads.
                var decoded = [CGImage?](repeating: nil, count: end - start)
                var outcome = [Int](repeating: 0, count: end - start)          // 0 decoded, 1 missing, 2 mismatched, 3 failed
                decoded.withUnsafeMutableBufferPointer { images in
                    outcome.withUnsafeMutableBufferPointer { results in
                        DispatchQueue.concurrentPerform(iterations: end - start) { k in
                            let row = rows[start + k]
                            guard !row.path.isEmpty, FileManager.default.fileExists(atPath: row.path) else { results[k] = 1; return }
                            guard let data = try? Data(contentsOf: URL(fileURLWithPath: row.path)) else { results[k] = 3; return }
                            guard ContentHash.sha1Hex(data) == row.id else { results[k] = 2; return }
                            guard let cg = try? ImageDecoding.cgImage(data: data, name: row.id) else { results[k] = 3; return }
                            images[k] = cg
                        }
                    }
                }
                // GPU: one image at a time.
                for k in 0..<(end - start) {
                    switch outcome[k] {
                    case 1: missing += 1
                    case 2: mismatched += 1
                    case 3: failed += 1
                    default:
                        do {
                            let r = try ResidualStatistics.measure(decoded[k]!)
                            values.replaceSubrange(((start + k) * width)..<((start + k + 1) * width), with: r)
                            measured += 1
                        } catch { failed += 1 }
                        LensRuntime.releaseMemory()
                    }
                }
                start = end
            }
            try FeatureShard.writeSide(.residual, values: values, for: name, in: store,
                                       metadata: ["residual": "warp19 mean and spread at \(TilePlane.maxDim) px", "measured": String(measured)],
                                       replacing: replacing)
            let report = ShardReport(shard: name, rows: rows.count, measured: measured, missing: missing, mismatched: mismatched, failed: failed,
                                     skipped: false, seconds: Date().timeIntervalSince(started))
            reports.append(report)
            note(String(format: "residual %d/%d %@: %d of %d measured, %d gone, %d changed, %d failed, %.0fs",
                        s + 1, names.count, name, measured, rows.count, missing, mismatched, failed, report.seconds))
        }
        return reports
    }
}
