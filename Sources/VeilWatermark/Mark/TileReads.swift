//
//  TileReads.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The mark's reads of an RGB plane, a block of tiles at a time: the fragility rate of
//        rows × cols tiles from any pixel origin (the residual unchanged, as FragilityGrid reads it),
//        and each tile's luma deviation, which weights how far its soft level is trusted.
//  PIN:  Fragility is WarpResidual.batch at both strengths through WarpTables.shared(quantizeLikeCV2:
//        true), chunked by WarpConstants.evalTileBudget: over the whole grid from the same origin it
//        equals NativePlane.fragility value for value (FragilityBandTests).
//

import Foundation
import MLX
import MLXAccelerate

enum TileReads {
    /// rows × cols tiles from (originX, originY) of `plane` ([H, W, 3]) as [rows·cols, 1024, 3], row-major.
    static func tiles(_ plane: MLXArray, originX: Int, originY: Int, rows: Int, cols: Int) -> MLXArray {
        let ts = WarpConstants.tileSize
        let region = plane[originY..<(originY + rows * ts), originX..<(originX + cols * ts), 0...]
        return region.reshaped([rows, ts, cols, ts, 3]).transposed(0, 2, 1, 3, 4).reshaped([rows * cols, ts * ts, 3])
    }

    /// The fragility rate of each tile, row-major.
    static func fragility(_ plane: MLXArray, originX: Int, originY: Int, rows: Int, cols: Int) -> [Float] {
        guard rows > 0, cols > 0 else { return [] }
        let tables = WarpTables.shared(quantizeLikeCV2: true)
        let all = tiles(plane, originX: originX, originY: originY, rows: rows, cols: cols)
        var out = [Float]()
        out.reserveCapacity(rows * cols)
        var a = 0
        while a < rows * cols {
            let b = min(a + WarpConstants.evalTileBudget, rows * cols)
            let chunk = all[a..<b]
            let low = WarpResidual.batch(chunk, forward: tables.lowForward, back: tables.lowBack)
            let high = WarpResidual.batch(chunk, forward: tables.highForward, back: tables.highBack)
            let fr = WarpResidual.fragility(low: low, high: high)
            MLX.eval(fr)
            out += fr.asArray(Float.self)
            a = b
        }
        return out
    }

    /// Each tile's luma deviation (population), row-major.
    static func texture(_ plane: MLXArray, originX: Int, originY: Int, rows: Int, cols: Int) -> [Float] {
        guard rows > 0, cols > 0 else { return [] }
        let t = tiles(plane, originX: originX, originY: originY, rows: rows, cols: cols)
        let weights = MLXArray([0.299, 0.587, 0.114] as [Float], [1, 1, 3])
        let luma = (t * weights).sum(axis: 2)                        // [N, 1024]
        let mean = luma.mean(axis: 1, keepDims: true)
        let deviation = MLX.sqrt(((luma - mean) * (luma - mean)).mean(axis: 1))
        MLX.eval(deviation)
        return deviation.asArray(Float.self)
    }
}
