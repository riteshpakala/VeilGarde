//
//  TileAgreement.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Where a match agrees: per tile of the image's codes, the share of its measured bits that equal
//        the stored signature's at the matched offset, as a TileMap an overlay tints and a digest draws.
//  PIN:  Value 2·agree/measured − 1 (1 all agree, −1 none), weight measured/4; a tile with no bit measured
//        against the stored grid (outside it, or masked) has weight 0. The same comparison as
//        Matcher.best's score, kept per tile.
//

import Foundation

extension Matcher {
    /// `crop`'s per-tile agreement with `stored` when crop tile (0, 0) sits on stored tile (dx, dy);
    /// the map is placed at (originX, originY) on the image the crop was read from.
    public static func agreement(crop: TileCodeGrid, stored: TileCodeGrid, dx: Int, dy: Int, originX: Int = 0, originY: Int = 0) -> TileMap {
        var values = [Float](repeating: 0, count: crop.rows * crop.cols)
        var weights = [Float](repeating: 0, count: crop.rows * crop.cols)
        for r in 0..<crop.rows {
            let sr = r + dy
            guard sr >= 0, sr < stored.rows else { continue }
            for c in 0..<crop.cols {
                let sc = c + dx
                guard sc >= 0, sc < stored.cols else { continue }
                let i = r * crop.cols + c, j = sr * stored.cols + sc
                let measured = crop.masks[i] & stored.masks[j]
                let bits = measured.nonzeroBitCount
                guard bits > 0 else { continue }
                let bad = ((crop.bits[i] ^ stored.bits[j]) & measured).nonzeroBitCount
                values[i] = 2 * Float(bits - bad) / Float(bits) - 1
                weights[i] = Float(bits) / 4
            }
        }
        return TileMap(rows: crop.rows, cols: crop.cols, values: values, weights: weights, originX: originX, originY: originY)
    }
}
