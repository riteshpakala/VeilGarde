//
//  CondensedData.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The condensed model's inputs for a set of joined images, ready to batch: each image's
//        tiles (the core's warp features, the tile's texture weight and its place on the grid),
//        their per-feature aggregates, the provenance vector (the nine capture values, the
//        noiseprint's P(camera) and whether it was measured), and DINOv2's fusion embedding. Every
//        value is standardized with statistics from the training images only.
//  PIN:  Tiles are padded to the largest grid (16 × 16 under the 512 cap) with a mask; the texture
//        weight enters twice, standardized as an input and raw as the weight of the textured vote.
//        A missing noiseprint reads 0 after standardization, with its flag 0.
//

import Foundation
import VeilGardeCore

/// The standardization a condensed model was trained with, written beside its weights.
public struct CondensedNormalizer: Codable, Sendable, Equatable {
    public var tileMean: [Float]
    public var tileStd: [Float]
    public var aggregateMean: [Float]
    public var aggregateStd: [Float]
    public var provenanceMean: [Float]
    public var provenanceStd: [Float]
    public var semanticMean: [Float]
    public var semanticStd: [Float]

    static func moments(_ rows: [[Float]], width: Int) -> (mean: [Float], std: [Float]) {
        var sum = [Double](repeating: 0, count: width), squares = sum, n = sum
        for row in rows {
            for j in 0..<width where row[j].isFinite { sum[j] += Double(row[j]); squares[j] += Double(row[j]) * Double(row[j]); n[j] += 1 }
        }
        let mean = (0..<width).map { n[$0] > 0 ? sum[$0] / n[$0] : 0 }
        let std = (0..<width).map { n[$0] > 1 ? max(1e-6, (squares[$0] / n[$0] - mean[$0] * mean[$0]).squareRoot()) : 1 }
        return (mean.map(Float.init), std.map(Float.init))
    }
}

/// The inputs of a set of images, flat and standardized.
struct CondensedSet {
    let count: Int
    let maxTiles: Int
    let tileChannels: Int
    let aggregateWidth: Int
    static let provenanceWidth = CaptureFeatures.count + 2
    static let semanticWidth = 384
    var tiles: [Float]
    var mask: [Float]
    var weights: [Float]
    var aggregates: [Float]
    var provenance: [Float]
    var semantic: [Float]
    var labels: [Float]
    /// Each row's image, in the join.
    var rows: [Int]

    /// The raw per-image pieces of `rows` of `join` over `columns`.
    static func raw(_ join: ResearchJoin, rows: [Int], columns: [Int]) -> (tiles: [[[Float]]], aggregates: [[Float]], provenance: [[Float]], semantic: [[Float]], texture: [[Float]]) {
        let f = join.tiles.data.features
        var tiles: [[[Float]]] = [], aggregates: [[Float]] = [], provenance: [[Float]] = [], semantic: [[Float]] = [], texture: [[Float]] = []
        for i in rows {
            let image = join.tiles.images[i], joined = join.images[i]
            var perTile: [[Float]] = [], tex: [Float] = []
            var values = [[Float]](repeating: [], count: columns.count)
            for (k, t) in image.range.enumerated() {
                let r = k / image.cols, c = k % image.cols
                let row = columns.map { join.tiles.data.x[t * f + $0] }
                for (j, v) in row.enumerated() { values[j].append(v) }
                perTile.append(row + [join.tiles.texture[t],
                                      image.rows > 1 ? Float(r) / Float(image.rows - 1) - 0.5 : 0,
                                      image.cols > 1 ? Float(c) / Float(image.cols - 1) - 0.5 : 0])
                tex.append(join.tiles.texture[t])
            }
            var aggregate: [Float] = []
            for v in values {
                let sorted = v.sorted(), n = Float(max(1, v.count))
                let mean = v.reduce(0, +) / n
                let spread = (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n).squareRoot()
                func q(_ p: Float) -> Float { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(p * Float(sorted.count - 1)))] }
                aggregate += [mean, spread, q(0.1), q(0.9)]
            }
            tiles.append(perTile)
            texture.append(tex)
            aggregates.append(aggregate)
            provenance.append(joined.cap + [joined.noiseprint])
            semantic.append(joined.dinoFusion)
        }
        return (tiles, aggregates, provenance, semantic, texture)
    }

    /// The normalizer from the training rows.
    static func normalizer(_ join: ResearchJoin, train: [Int], columns: [Int]) -> CondensedNormalizer {
        let r = raw(join, rows: train, columns: columns)
        let tileRows = r.tiles.flatMap { $0.map { Array($0.prefix(columns.count + 1)) } }
        let t = CondensedNormalizer.moments(tileRows, width: columns.count + 1)
        let a = CondensedNormalizer.moments(r.aggregates, width: 4 * columns.count)
        let p = CondensedNormalizer.moments(r.provenance, width: provenanceWidth - 1)
        let s = CondensedNormalizer.moments(r.semantic, width: semanticWidth)
        return CondensedNormalizer(tileMean: t.mean, tileStd: t.std, aggregateMean: a.mean, aggregateStd: a.std, provenanceMean: p.mean,
                                   provenanceStd: p.std, semanticMean: s.mean, semanticStd: s.std)
    }

    init(_ join: ResearchJoin, rows: [Int], columns: [Int], normalizer z: CondensedNormalizer, maxTiles: Int = 256) {
        let r = Self.raw(join, rows: rows, columns: columns)
        count = rows.count
        self.maxTiles = maxTiles
        tileChannels = columns.count + 3
        aggregateWidth = 4 * columns.count
        self.rows = rows
        labels = rows.map { Float(join.images[$0].label) }
        tiles = [Float](repeating: 0, count: count * maxTiles * tileChannels)
        mask = [Float](repeating: 0, count: count * maxTiles)
        weights = mask
        aggregates = []
        provenance = []
        semantic = []
        aggregates.reserveCapacity(count * aggregateWidth)
        provenance.reserveCapacity(count * Self.provenanceWidth)
        semantic.reserveCapacity(count * Self.semanticWidth)
        let standardized = columns.count + 1
        for n in 0..<count {
            for (k, tile) in r.tiles[n].prefix(maxTiles).enumerated() {
                let base = (n * maxTiles + k) * tileChannels
                for j in 0..<tileChannels {
                    tiles[base + j] = j < standardized ? (tile[j] - z.tileMean[j]) / z.tileStd[j] : tile[j]
                }
                mask[n * maxTiles + k] = 1
                weights[n * maxTiles + k] = max(0, r.texture[n][k]) + 1e-6
            }
            aggregates += r.aggregates[n].enumerated().map { ($1 - z.aggregateMean[$0]) / z.aggregateStd[$0] }
            let p = r.provenance[n]
            provenance += p.enumerated().map { $1.isFinite ? ($1 - z.provenanceMean[$0]) / z.provenanceStd[$0] : 0 } + [p.last!.isFinite ? 1 : 0]
            semantic += r.semantic[n].enumerated().map { $1.isFinite ? ($1 - z.semanticMean[$0]) / z.semanticStd[$0] : 0 }
        }
    }

    /// The raw per-image vectors a gradient-boosted comparator reads: aggregates, provenance, semantic.
    static func flat(_ join: ResearchJoin, rows: [Int], columns: [Int]) -> (aggregates: [[Float]], provenance: [[Float]], semantic: [[Float]]) {
        let r = raw(join, rows: rows, columns: columns)
        return (r.aggregates, r.provenance, r.semantic)
    }
}
