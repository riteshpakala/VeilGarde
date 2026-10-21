//
//  Synthetic.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A throwaway work area for the engine's tests: a copy of the shipped bundle as the parent,
//        a seeded features-only store with every category the recipes read, and a dataset whose
//        tiles are already cached, so a full recipe trains without the GPU or a single image.
//        Each cached image names a source pool (a quarter of the reals are "iphone"), which only
//        the core study reads.
//

import Foundation
import VeilGardeCore
@testable import VeilGardeTraining

struct SyntheticArea {
    let root: URL
    let area: WorkArea
    let parent: URL
    let store: URL
    let dataset: URL

    static func make(images: Int = 800, mixedWarp: Bool = false) throws -> SyntheticArea {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vg-engine-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // The parent: the shipped bundle's resources, copied.
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        try fm.copyItem(at: Fixture.resources, to: parent)
        let area = WorkArea(root: root.appendingPathComponent("area", isDirectory: true))
        let store = area.root.appendingPathComponent("store/shards", isDirectory: true)
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        try writeStore(store, mixedWarp: mixedWarp)
        let dataset = root.appendingPathComponent("toy/dataset.jsonl")
        try writeDataset(dataset, images: images, cache: area.root.appendingPathComponent("store/tiles/dataset", isDirectory: true))
        return SyntheticArea(root: root, area: area, parent: parent, store: store, dataset: dataset)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    // MARK: The store

    static func writeStore(_ directory: URL, mixedWarp: Bool) throws {
        var rng = SplitMix64(seed: 7)
        func gauss() -> Float {
            let u = max(1e-12, rng.unit()), v = rng.unit()
            return Float((-2 * log(u)).squareRoot() * cos(2 * .pi * v))
        }
        let sources = ["civitai", "commons_native", "wikimedia", "inat", "hf_faces", "openverse", "mj_v6"]
        let plan: [(category: String, label: Int, count: Int)] = [
            ("art", 1, 150), ("art", 0, 100), ("blur", 1, 100), ("blur", 0, 80), ("human", 1, 120), ("human", 0, 200),
            ("cgi", 1, 80), ("cgi", 0, 60), ("preview", 1, 60), ("preview", 0, 60), ("photo", 0, 220),
        ]
        let categoryIndex = ["art": 0, "blur": 1, "human": 2, "cgi": 3, "preview": 4, "photo": 5]
        for (shardName, newGen) in [("base_a", false), ("scrape_20260101", true)] {
            var rows: [FeatureRow] = []
            var columns: [FeatureColumn: [Float]] = Dictionary(uniqueKeysWithValues: FeatureColumn.allCases.map { ($0, [Float]()) })
            var serial = 0
            for p in plan where !newGen || p.label == 1 {
                let n = newGen ? p.count / 3 : p.count
                for _ in 0..<n {
                    serial += 1
                    let id = ContentHash.sha1Hex(Data("\(shardName)-\(serial)".utf8))
                    let golden = !newGen && p.category == "photo" && serial % 7 == 0
                    let path = golden && serial % 21 == 0 ? "/pools/bsky/\(serial).jpg" : "/pools/\(p.category)/\(serial).jpg"
                    rows.append(FeatureRow(id: id, path: path, label: p.label, category: p.category, source: sources[serial % sources.count],
                                           nsfw: serial % 53 == 0, golden: golden, warpModel: mixedWarp && newGen ? "0123456789ab" : nil))
                    let c = categoryIndex[p.category]!
                    var norm = (0..<384).map { _ in gauss() }
                    if p.label == 1 { for j in (c * 10)..<(c * 10 + 10) { norm[j] += 1.6 } }
                    var fusion = (0..<384).map { _ in gauss() }
                    if p.label == 1 { for j in 0..<12 { fusion[j] += 1.0 } }
                    columns[.dinoNorm]! += norm
                    columns[.dinoFusion]! += fusion
                    let present: Float = p.label == 0 && serial % 3 == 0 ? 1 : 0
                    columns[.cap]! += [Float(rng.unit() * 60), 1, present, 2000, Float(rng.unit() * 10), 0.5, 0.5, 0.5, 0]
                    columns[.warp]!.append(Float(min(1, max(0, (p.label == 1 ? 0.6 : 0.4) + 0.15 * Double(gauss())))))
                    columns[.sharp]! += [Float(rng.unit() * 40), Float(rng.unit() * 40), Float(rng.unit() * 2)]
                    columns[.noiseprint]!.append(Float(min(1, max(0, (p.label == 0 ? 0.6 : 0.3) + 0.2 * Double(gauss())))))
                }
            }
            try FeatureShard(name: shardName, rows: rows, columns: columns).write(to: directory)
        }
    }

    // MARK: The dataset and its cached tiles

    static func writeDataset(_ url: URL, images: Int, cache: URL) throws {
        var rng = SplitMix64(seed: 11)
        let records = (0..<images).map { i in ImageRecord(path: "img/\(i).png", label: i % 2, stem: String(format: "img_%04d", i)) }
        let manifest = ImageManifest(records: records, root: url.deletingLastPathComponent()).withSplits()
        try manifest.write(to: url)
        var tileImages: [TileImage] = [], features: [Float] = [], texture: [Float] = []
        for (i, r) in manifest.records.enumerated() {
            let pool = r.label == 1 ? (i % 4 == 1 ? "final_gen" : "agvr_gen") : (i % 8 == 0 ? "iphone" : "final_real")
            tileImages.append(TileImage(stem: r.stem, path: r.path, label: r.label, split: r.split!, pool: pool, tag: nil, rows: 2, cols: 2,
                                        start: texture.count, width: 64, height: 64))
            for _ in 0..<4 {
                var row = (0..<WarpFeatures.count).map { _ in Float(rng.unit()) }
                row[0] = Float(rng.unit()) * 0.6 + (r.label == 1 ? 0.35 : 0)      // FR carries the label
                features += row
                texture.append(Float(0.2 + rng.unit()))
            }
        }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try TileShard(name: "tiles_0000", images: tileImages, features: features, texture: texture,
                      metadata: ["manifest_sha256": manifest.sha256]).write(to: cache)
    }
}
