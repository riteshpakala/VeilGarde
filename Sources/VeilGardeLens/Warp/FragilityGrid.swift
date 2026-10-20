//
//  FragilityGrid.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The warp lens's fragility rate for every full 32-px tile of an image at its native
//        resolution, from any tile origin: the per-tile pattern the watermark reads. Nothing is
//        resized, so a crop of the image sees the same tiles (shifted by whole tiles when the
//        crop's origin is found).
//  PIN:  The detector's own residual (WarpResidual.batch at both strengths, then fragility) on
//        tiles cut from the native RGB plane starting at (originX, originY); only full tiles,
//        no padding; chunked by the evaluation budget.
//

import CoreGraphics
import Foundation
import MLX
import MLXAccelerate

public struct FragilityGrid: Sendable, Equatable {
    public var rows: Int
    public var cols: Int
    /// Row-major, rows × cols.
    public var values: [Float]
    public var originX: Int
    public var originY: Int

    public init(rows: Int, cols: Int, values: [Float], originX: Int = 0, originY: Int = 0) {
        self.rows = rows
        self.cols = cols
        self.values = values
        self.originX = originX
        self.originY = originY
    }

    public subscript(r: Int, c: Int) -> Float { values[r * cols + c] }
}

/// An image's native RGB plane (0–255), decoded once and cut at many origins.
public struct NativePlane {
    public let array: MLXArray
    public let width: Int
    public let height: Int

    public init(_ cg: CGImage) throws {
        let p = try ImageLoading.prepare(cg, maxDim: 0, patchSize: 1)
        array = MLXArray(p.pixels, [p.realHeight, p.realWidth, 3])
        width = p.realWidth
        height = p.realHeight
    }

    /// The fragility rate of every full tile from (originX, originY).
    public func fragility(originX: Int = 0, originY: Int = 0, quantizeLikeCV2: Bool = true) -> FragilityGrid {
        let ts = WarpConstants.tileSize
        let rows = max(0, (height - originY) / ts), cols = max(0, (width - originX) / ts)
        guard rows > 0, cols > 0 else { return FragilityGrid(rows: rows, cols: cols, values: [], originX: originX, originY: originY) }
        let tables = WarpTables.shared(quantizeLikeCV2: quantizeLikeCV2)
        let region = array[originY..<(originY + rows * ts), originX..<(originX + cols * ts), 0...]
        let tiles = region.reshaped([rows, ts, cols, ts, 3]).transposed(0, 2, 1, 3, 4).reshaped([rows * cols, ts * ts, 3])
        var out = [Float]()
        out.reserveCapacity(rows * cols)
        var a = 0
        while a < rows * cols {
            let b = min(a + WarpConstants.evalTileBudget, rows * cols)
            let chunk = tiles[a..<b]
            let low = WarpResidual.batch(chunk, forward: tables.lowForward, back: tables.lowBack)
            let high = WarpResidual.batch(chunk, forward: tables.highForward, back: tables.highBack)
            let fr = WarpResidual.fragility(low: low, high: high)
            MLX.eval(fr)
            out += fr.asArray(Float.self)
            a = b
        }
        return FragilityGrid(rows: rows, cols: cols, values: out, originX: originX, originY: originY)
    }
}
