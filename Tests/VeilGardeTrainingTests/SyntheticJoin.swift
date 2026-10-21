//
//  SyntheticJoin.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The signals the redundancy check and the condensed model join to a synthetic area's tile
//        cache: a store shard of final_mixed-like rows (DINOv2 carrying a little of the label,
//        capture absent but on some reals), a scratch shard of noiseprint scores (cameras high),
//        and a small battery with its own tile cache and every column, HARD and RATCHET groups.
//

import Foundation
import VeilGardeCore
@testable import VeilGardeTraining

struct SyntheticJoin {
    let store: URL
    let aux: URL
    let batteryTiles: URL

    static func make(_ s: SyntheticArea, battery: Int = 24) throws -> SyntheticJoin {
        var rng = SplitMix64(seed: 23)
        func gauss() -> Float {
            let u = max(1e-12, rng.unit()), v = rng.unit()
            return Float((-2 * log(u)).squareRoot() * cos(2 * .pi * v))
        }
        let cache = s.area.root.appendingPathComponent("store/tiles/dataset", isDirectory: true)
        let shards = try TileCache(directory: cache).load()
        let images = shards.flatMap(\.images)
        let store = s.area.root.appendingPathComponent("store/fm", isDirectory: true), aux = s.area.root.appendingPathComponent("store/aux", isDirectory: true)
        func columns(_ label: Int, pool: String?) -> [FeatureColumn: [Float]] {
            var fusion = (0..<384).map { _ in gauss() }
            if label == 1 { for j in 0..<8 { fusion[j] += 0.8 } }
            let present: Float = label == 0 && rng.unit() < 0.3 ? 1 : 0
            let camera = pool == "iphone" ? 0.8 : (label == 0 ? 0.55 : 0.3)
            return [.dinoFusion: fusion, .dinoNorm: (0..<384).map { _ in gauss() }, .cap: [Float(rng.unit() * 60), 1, present, 2000, Float(rng.unit()), 0.5, 0.5, 0.5, 0],
                    .warp: [.nan], .sharp: [.nan, .nan, .nan], .noiseprint: [Float(min(1, max(0, camera + 0.15 * Double(gauss()))))]]
        }
        var rows: [FeatureRow] = [], npRows: [FeatureRow] = []
        var main: [FeatureColumn: [Float]] = Dictionary(uniqueKeysWithValues: FeatureColumn.allCases.map { ($0, [Float]()) })
        var scratch = main
        for image in images {
            let id = ContentHash.sha1Hex(Data("fm-\(image.stem)".utf8))
            let path = "/data/final_mixed/\(image.label == 1 ? "generated" : "real")/\(image.stem).png"
            let c = columns(image.label, pool: image.pool)
            rows.append(FeatureRow(id: id, path: path, label: image.label, category: "v197", source: "v197"))
            npRows.append(FeatureRow(id: id, path: path, label: image.label, category: image.pool ?? "x", source: "final_mixed"))
            for column in FeatureColumn.allCases {
                main[column]! += column == .noiseprint ? [.nan] : c[column]!
                scratch[column]! += column == .noiseprint ? c[column]! : [Float](repeating: .nan, count: column.width)
            }
        }
        try FeatureShard(name: "fm_rows", rows: rows, columns: main).write(to: store)
        try FeatureShard(name: "final_mixed_np", rows: npRows, columns: scratch).write(to: aux)

        // The battery: the first test images' tiles under battery paths, every column measured.
        let all = TileSet.gather(shards, partitions: [.test])
        var tileImages: [TileImage] = [], features: [Float] = [], texture: [Float] = []
        var batteryRows: [FeatureRow] = []
        var batteryColumns: [FeatureColumn: [Float]] = Dictionary(uniqueKeysWithValues: FeatureColumn.allCases.map { ($0, [Float]()) })
        for (k, image) in all.images.prefix(battery).enumerated() {
            let group = image.label == 1 ? (k % 2 == 0 ? "user_gen" : "gen_semantic") : (k % 2 == 0 ? "native_cam" : "wildlife_real")
            let mode = group == "user_gen" || group == "native_cam" ? "HARD" : "RATCHET"
            let path = "/battery/\(group)/\(image.stem).png"
            tileImages.append(TileImage(stem: "\(group)__\(image.stem)", path: path, label: image.label, split: .test, pool: group, tag: mode,
                                        rows: image.rows, cols: image.cols, start: texture.count, width: image.width, height: image.height))
            features += all.data.x[(image.start * all.data.features)..<((image.start + image.count) * all.data.features)]
            texture += all.texture[image.range]
            batteryRows.append(FeatureRow(id: ContentHash.sha1Hex(Data(path.utf8)), path: path, label: image.label, category: group, source: "battery"))
            for (column, values) in columns(image.label, pool: group == "native_cam" ? "iphone" : nil) { batteryColumns[column]! += values }
        }
        let batteryTiles = s.area.root.appendingPathComponent("store/tiles/battery", isDirectory: true)
        try FileManager.default.createDirectory(at: batteryTiles, withIntermediateDirectories: true)
        try TileShard(name: "tiles_0000", images: tileImages, features: features, texture: texture).write(to: batteryTiles)
        try FeatureShard(name: "battery_all", rows: batteryRows, columns: batteryColumns).write(to: aux)
        return SyntheticJoin(store: store, aux: aux, batteryTiles: batteryTiles)
    }
}
