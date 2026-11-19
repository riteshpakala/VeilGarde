//
//  TileMap.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A value and a weight per tile, placed on the image it was read from: what an overlay tints
//        and a digest draws. Agreement maps use it (the passive codes against a stored signature, the
//        mark's soft levels against the levels it decoded): 1 agrees, −1 disagrees, and the weight says
//        how much was measured there.
//

import Foundation

public struct TileMap: Codable, Sendable, Equatable {
    public var rows: Int
    public var cols: Int
    /// Row-major, each in −1…1.
    public var values: [Float]
    /// Row-major, each in 0…1.
    public var weights: [Float]
    /// Where tile (0, 0) sits on the image the map was read from, in pixels.
    public var originX: Int
    public var originY: Int
    public var tile: Int

    public init(rows: Int, cols: Int, values: [Float], weights: [Float], originX: Int = 0, originY: Int = 0, tile: Int = WarpConstants.tileSize) {
        self.rows = rows
        self.cols = cols
        self.values = values
        self.weights = weights
        self.originX = originX
        self.originY = originY
        self.tile = tile
    }

    public subscript(r: Int, c: Int) -> (value: Float, weight: Float) { (values[r * cols + c], weights[r * cols + c]) }

    /// The weighted mean value: how much of the map agrees overall.
    public var meanValue: Float {
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        return zip(values, weights).reduce(0) { $0 + $1.0 * $1.1 } / total
    }
}
