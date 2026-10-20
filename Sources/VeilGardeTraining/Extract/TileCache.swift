//
//  TileCache.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The warp tile model's training data on disk: shards of per-tile features cut from a
//        manifest's images, each tile with its texture weight, each image with its grid, label and
//        partition. A model trains on the tiles and is evaluated per image without reopening one.
//  PIN:  `<shard>.tiles.safetensors` holds `features` F32 [N, 19] (WarpFeatures order) and
//        `texture` F32 [N]; `<shard>.images.json` lists the shard's images in order, each owning
//        the tile range [start, start + rows·cols) in row-major grid order. The header names the
//        format, the feature order, the geometry (max side 512, 32-px tiles, cv2-quantized warp)
//        and the SHA-256 of the manifest the shard was cut from. Shards are written once.
//

import Foundation
import VeilGardeCore

public struct TileImage: Codable, Sendable, Equatable {
    public var stem: String
    public var path: String
    public var label: Int
    public var split: Partition
    public var pool: String?
    public var tag: String?
    public var rows: Int
    public var cols: Int
    public var start: Int
    /// The scored (512-capped) size.
    public var width: Int
    public var height: Int

    public init(stem: String, path: String, label: Int, split: Partition, pool: String? = nil, tag: String? = nil, rows: Int, cols: Int,
                start: Int, width: Int, height: Int) {
        self.stem = stem
        self.path = path
        self.label = label
        self.split = split
        self.pool = pool
        self.tag = tag
        self.rows = rows
        self.cols = cols
        self.start = start
        self.width = width
        self.height = height
    }

    public var count: Int { rows * cols }
    public var range: Range<Int> { start..<(start + count) }
}

public struct TileShard: Sendable {
    public static let format = "veilgarde-tile-shard-v1"

    public let name: String
    public var images: [TileImage]
    /// [tiles × featureCount], row-major.
    public var features: [Float]
    public var texture: [Float]
    public var featureCount: Int
    public var metadata: [String: String]

    public init(name: String, images: [TileImage], features: [Float], texture: [Float], featureCount: Int = WarpFeatures.count,
                metadata: [String: String] = [:]) {
        self.name = name
        self.images = images
        self.features = features
        self.texture = texture
        self.featureCount = featureCount
        self.metadata = metadata
    }

    public var tileCount: Int { texture.count }

    public static func tensorsURL(_ directory: URL, _ name: String) -> URL { directory.appendingPathComponent("\(name).tiles.safetensors") }
    public static func imagesURL(_ directory: URL, _ name: String) -> URL { directory.appendingPathComponent("\(name).images.json") }

    public func write(to directory: URL) throws {
        let tensors = Self.tensorsURL(directory, name), list = Self.imagesURL(directory, name)
        if FileManager.default.fileExists(atPath: tensors.path) || FileManager.default.fileExists(atPath: list.path) {
            throw VeilGardeFailure.exists("the tile shard \(name) already exists in \(directory.path)")
        }
        guard features.count == tileCount * featureCount, images.reduce(0, { $0 + $1.count }) == tileCount else {
            throw VeilGardeFailure.internalError("tile shard \(name): \(features.count) values, \(tileCount) tiles, \(images.count) images do not agree")
        }
        var header = metadata
        header["format"] = Self.format
        header["feature_order"] = WarpFeatures.names.joined(separator: ",")
        header["tiles"] = String(tileCount)
        header["images"] = String(images.count)
        header["core_version"] = VeilGardeVersion.string
        // The image list first: a shard whose tensors exist is complete.
        try JSONCoding.write(images, to: list)
        try SafetensorsWriter.write([
            .init("features", shape: [tileCount, featureCount], .float32(features)),
            .init("texture", shape: [tileCount], .float32(texture)),
        ], metadata: header, to: tensors)
    }

    public static func read(_ name: String, in directory: URL) throws -> TileShard {
        let file = try SafetensorsFile(url: tensorsURL(directory, name))
        guard file.metadata["format"] == format else { throw VeilGardeFailure.data("\(name).tiles.safetensors is not a \(format) shard") }
        let images = try JSONCoding.read([TileImage].self, from: imagesURL(directory, name))
        let features = try file.float32("features"), texture = try file.float32("texture")
        let width = try file.tensor("features").shape.last ?? WarpFeatures.count
        return TileShard(name: name, images: images, features: features, texture: texture, featureCount: width, metadata: file.metadata)
    }
}

/// A directory of tile shards.
public struct TileCache: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// Complete shards (their tensors written), in name order.
    public func shardNames() -> [String] {
        WorkArea.listing(directory).filter { $0.hasSuffix(".tiles.safetensors") }.map { String($0.dropLast(".tiles.safetensors".count)) }
    }

    public func load() throws -> [TileShard] { try shardNames().map { try TileShard.read($0, in: directory) } }

    /// The stems already in the cache.
    public func stems() throws -> Set<String> {
        var out = Set<String>()
        for name in shardNames() { for image in try JSONCoding.read([TileImage].self, from: TileShard.imagesURL(directory, name)) { out.insert(image.stem) } }
        return out
    }
}

/// Tiles gathered across shards for one partition: the boosting matrix plus each image's slice.
public struct TileSet: Sendable {
    public var images: [TileImage]
    public var data: BoostDataset
    public var texture: [Float]

    /// The tiles of every image in `partitions` (and passing `include`), labelled with their image's label.
    public static func gather(_ shards: [TileShard], partitions: Set<Partition>, include: (TileImage) -> Bool = { _ in true }) -> TileSet {
        var images: [TileImage] = [], x: [Float] = [], y: [Float] = [], texture: [Float] = []
        let f = shards.first?.featureCount ?? WarpFeatures.count
        for shard in shards {
            for image in shard.images where partitions.contains(image.split) && include(image) {
                var moved = image
                moved.start = texture.count
                images.append(moved)
                x.append(contentsOf: shard.features[(image.start * f)..<((image.start + image.count) * f)])
                texture.append(contentsOf: shard.texture[image.range])
                y.append(contentsOf: [Float](repeating: Float(image.label), count: image.count))
            }
        }
        return TileSet(images: images, data: BoostDataset(x: x, y: y, features: f), texture: texture)
    }

    public var tileCount: Int { texture.count }
}
