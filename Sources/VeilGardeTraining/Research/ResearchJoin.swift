//
//  ResearchJoin.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Images with every signal the studies weigh against the warp residual: their cached warp
//        tiles, their DINOv2 embeddings and capture values, and their noiseprint. For final_mixed,
//        the tiles come from the tile cache (by file stem), DINOv2 and capture from the store's
//        rows (by path), and the noiseprint from a scratch store it was measured into (by id, the
//        SHA-1 of the file's bytes). For the battery, one scratch shard holds every column and
//        joins its own tile cache by path. The redundancy check and the condensed model read them.
//  PIN:  The store's final_mixed rows are the research's own extraction (category v197): DINOv2 from
//        the Python reference, and capture's present flag at its older threshold (20, not 30). Only
//        images found in every source join; each keeps the tile cache's partition.
//

import Foundation
import VeilGardeCore
import VeilGardeLens

public struct JoinedImage: Sendable {
    public var stem: String
    public var path: String
    public var id: String
    public var label: Int
    public var split: Partition
    public var pool: String?
    public var tag: String?
    public var dinoFusion: [Float]
    /// NaN where the store has no 360×640 embedding for the image.
    public var dinoNorm: [Float]
    public var cap: [Float]
    /// P(camera); NaN when the image was too small or blank to score.
    public var noiseprint: Float
}

public struct ResearchJoin: Sendable {
    /// The joined images' tiles: tiles.images[i] is images[i].
    public var tiles: TileSet
    public var images: [JoinedImage]
    /// What joined and what did not.
    public var counts: [String: Int]

    static func stem(_ path: String) -> String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    /// final_mixed: its tile cache, the store's rows under a final_mixed folder, a scratch shard's noiseprint.
    public static func finalMixed(tiles: URL, store: URL, aux: URL, auxShard: String = "final_mixed_np") throws -> ResearchJoin {
        let selection = try FeatureStore(directory: store).select(columns: [.dinoFusion, .dinoNorm, .cap]) { $0.path.contains("/final_mixed/") }
        var byStem: [String: Int] = [:]
        for (i, row) in selection.rows.enumerated() where byStem[stem(row.path)] == nil { byStem[stem(row.path)] = i }
        let scratch = try FeatureStore(directory: aux).select(columns: [.noiseprint], shards: [auxShard])
        var noiseprint: [String: Float] = [:]
        for i in 0..<scratch.count { noiseprint[scratch.rows[i].id] = scratch.vector(.noiseprint, row: i).first ?? .nan }
        let shards = try TileCache(directory: tiles).load()
        guard !shards.isEmpty else { throw VeilGardeFailure.missing("no tile cache at \(tiles.path)") }
        let tileSet = TileSet.gather(shards, partitions: Set(Partition.allCases), include: { image in
            byStem[image.stem].map { noiseprint[selection.rows[$0].id] != nil } ?? false
        })
        let images = tileSet.images.map { image -> JoinedImage in
            let i = byStem[image.stem]!, row = selection.rows[i]
            return JoinedImage(stem: image.stem, path: row.path, id: row.id, label: image.label, split: image.split, pool: image.pool, tag: image.tag,
                               dinoFusion: Array(selection.vector(.dinoFusion, row: i)), dinoNorm: Array(selection.vector(.dinoNorm, row: i)),
                               cap: Array(selection.vector(.cap, row: i)), noiseprint: noiseprint[row.id]!)
        }
        let cached = shards.reduce(0) { $0 + $1.images.count }
        return ResearchJoin(tiles: tileSet, images: images, counts: ["store rows": selection.count, "store stems": byStem.count, "noiseprint rows": scratch.count,
                                                                     "cached images": cached, "joined": images.count])
    }

    /// The battery: its tile cache and one scratch shard holding every column, joined by path.
    public static func battery(tiles: URL, aux: URL, shard: String = "battery_all") throws -> ResearchJoin {
        let scratch = try FeatureStore(directory: aux).select(columns: Set(FeatureColumn.allCases), shards: [shard])
        var byPath: [String: Int] = [:]
        for (i, row) in scratch.rows.enumerated() where byPath[row.path] == nil { byPath[row.path] = i }
        let shards = try TileCache(directory: tiles).load()
        guard !shards.isEmpty else { throw VeilGardeFailure.missing("no tile cache at \(tiles.path)") }
        let tileSet = TileSet.gather(shards, partitions: Set(Partition.allCases), include: { byPath[$0.path] != nil })
        let images = tileSet.images.map { image -> JoinedImage in
            let i = byPath[image.path]!, row = scratch.rows[i]
            return JoinedImage(stem: image.stem, path: row.path, id: row.id, label: image.label, split: image.split, pool: image.pool, tag: image.tag,
                               dinoFusion: Array(scratch.vector(.dinoFusion, row: i)), dinoNorm: Array(scratch.vector(.dinoNorm, row: i)),
                               cap: Array(scratch.vector(.cap, row: i)), noiseprint: scratch.vector(.noiseprint, row: i).first ?? .nan)
        }
        return ResearchJoin(tiles: tileSet, images: images, counts: ["scratch rows": scratch.count, "joined": images.count])
    }

    /// The images of these partitions, by index.
    public func indices(in partitions: Set<Partition>) -> [Int] { images.indices.filter { partitions.contains(images[$0].split) } }
}

/// What the warp residual says about one image under one warp model: its weighted score and tile
/// vote, its three sharpness values, and the mean and spread of each feature the model splits on.
public struct ResidualView: Sendable {
    public var weighted: Float
    public var vote: Float
    public var sharp: [Float]
    public var aggregates: [Float]

    public var vector: [Float] { [weighted, vote] + sharp + aggregates }

    /// Every image of `tiles` under `model`, the aggregates over `columns`.
    public static func all(_ model: GBDTModel, _ tiles: TileSet, columns: [Int]) -> [ResidualView] {
        let scores = WarpTrainer.imageScores(model, tiles)
        let parameters = WarpParameters(), f = tiles.data.features
        return tiles.images.enumerated().map { k, image in
            let p = Array(scores.tileProbabilities[image.range]), tex = Array(tiles.texture[image.range])
            let grid = (0..<image.rows).map { Array(p[($0 * image.cols)..<(($0 + 1) * image.cols)]) }
            let texGrid = (0..<image.rows).map { Array(tex[($0 * image.cols)..<(($0 + 1) * image.cols)]) }
            let map = WeightMap.build(patchGrid: grid, texWeights: texGrid, parameters: parameters.weightMap)
            let s = SharpnessFeatures.measure(texWeights: texGrid, weightMap: map)
            var aggregates: [Float] = []
            for c in columns {
                var sum = 0.0, squares = 0.0
                for t in image.range { let v = Double(tiles.data.x[t * f + c]); sum += v; squares += v * v }
                let n = Double(max(1, image.count)), mean = sum / n
                aggregates += [Float(mean), Float(max(0, squares / n - mean * mean).squareRoot())]
            }
            return ResidualView(weighted: scores.weighted[k], vote: scores.majority[k], sharp: [s.salientSharp, s.globalSharp, s.sharpRatio], aggregates: aggregates)
        }
    }
}
