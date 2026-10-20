//
//  TileExtractor.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Cuts a manifest's images into the tile cache: each image decoded, capped at 512, padded
//        to the 32-px grid and run through the warp lens's feature pass, the same code the
//        detector scores with, so the trained model sees exactly the tiles it will be asked about.
//  PIN:  One MLX workload, on the calling thread, one image at a time; up to `prefetch` images
//        are decoded, capped and padded ahead on CPU threads (ImageLoading.prepare, the loader's
//        own CPU half, so the bytes are the detector's), and MLX's buffer cache is bounded and
//        released after every image (an unbounded cache reached 38 GB resident after 400
//        iPhone photos). Shards of `perShard` images in manifest order; stems already cached are
//        skipped, so an interrupted run resumes where it stopped (a partly written shard is cut
//        again). An image that fails to decode or is smaller than one tile is skipped and
//        reported, never fatal.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens

public struct TileExtraction: Codable, Sendable, Equatable {
    public var shardsWritten: [String] = []
    public var images = 0
    public var tiles = 0
    public var skippedCached = 0
    public var failed: [String] = []
    public var seconds = 0.0
}

public enum TileExtractor {
    public static let defaultPerShard = 500

    public static func extract(_ manifest: ImageManifest, into cache: TileCache, perShard: Int = defaultPerShard, maxDim: Int = 512,
                               prefetch: Int = 6, note: (String) -> Void = { _ in }) throws -> TileExtraction {
        let started = Date()
        let manifest = manifest.withSplits()
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let cached = try cache.stems()
        var report = TileExtraction()
        let pending = manifest.records.filter { !cached.contains($0.stem) }
        report.skippedCached = manifest.count - pending.count
        var shardIndex = cache.shardNames().count
        let manifestSHA = manifest.sha256
        var batch = TileShard(name: "", images: [], features: [], texture: [])
        func flush() throws {
            guard !batch.images.isEmpty else { return }
            let shard = TileShard(name: String(format: "tiles_%04d", shardIndex), images: batch.images, features: batch.features,
                                  texture: batch.texture, metadata: ["manifest_sha256": manifestSHA, "max_dim": String(maxDim),
                                                                     "tile": String(WarpConstants.tileSize), "warp": "cv2-quantized"])
            try shard.write(to: cache.directory)
            report.shardsWritten.append(shard.name)
            note("tiles: wrote \(shard.name) (\(shard.images.count) images, \(shard.tileCount) tiles)")
            shardIndex += 1
            batch = TileShard(name: "", images: [], features: [], texture: [])
        }
        // CPU work (decode, cap, pad) runs ahead on a concurrent queue; the GPU pass and the
        // writes stay on this thread, in manifest order.
        LensRuntime.configureGPUMemory()
        let ahead = max(1, min(prefetch, pending.count))
        let slots = pending.map { _ in Prefetched() }
        let queue = DispatchQueue(label: "veilgarde.tiles.prepare", qos: .userInitiated, attributes: .concurrent)
        let gate = DispatchSemaphore(value: ahead)
        let feeder = DispatchQueue(label: "veilgarde.tiles.feed")
        let stop = StopFlag()
        defer {
            // An early exit (a failed shard write) must not leave the feeder waiting forever.
            stop.set()
            for _ in 0..<ahead { gate.signal() }
        }
        feeder.async {
            for (k, record) in pending.enumerated() {
                gate.wait()
                if stop.isSet { return }
                let url = manifest.url(record)
                queue.async {
                    let slot = slots[k]
                    do {
                        let cg = try ImageDecoding.cgImage(contentsOf: url)
                        slot.prepared = try ImageLoading.prepare(cg, maxDim: maxDim, patchSize: WarpConstants.tileSize)
                    } catch { slot.error = error }
                    slot.ready.signal()
                }
            }
        }
        for (k, record) in pending.enumerated() {
            let slot = slots[k]
            slot.ready.wait()
            gate.signal()
            do {
                if let error = slot.error { throw error }
                let t = WarpLens.trainingTiles(prepared: slot.prepared!)
                slot.prepared = nil
                guard t.map.count > 0 else { throw VeilGardeFailure.data("no tiles") }
                batch.images.append(TileImage(stem: record.stem, path: record.path, label: record.label, split: record.split ?? .train,
                                              pool: record.pool, tag: record.tag, rows: t.map.tileRows, cols: t.map.tileCols,
                                              start: batch.texture.count, width: t.geometry.imageWidth, height: t.geometry.imageHeight))
                batch.features.append(contentsOf: t.map.values)
                batch.texture.append(contentsOf: t.texture)
                report.images += 1
                report.tiles += t.map.count
            } catch {
                report.failed.append(record.path)
                note("tiles: skipped \(record.path): \(error)")
            }
            LensRuntime.releaseMemory()
            if batch.images.count == perShard { try flush() }
            if (k + 1) % 250 == 0 {
                let rate = Double(k + 1) / max(1e-9, Date().timeIntervalSince(started))
                note(String(format: "tiles: %d of %d images (%.1f/s)", k + 1, pending.count, rate))
            }
        }
        try flush()
        report.seconds = Date().timeIntervalSince(started)
        return report
    }
}

/// One image's CPU half, handed from the prefetch threads to the GPU thread.
private final class Prefetched: @unchecked Sendable {
    var prepared: PreparedImage?
    var error: Error?
    let ready = DispatchSemaphore(value: 0)
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
