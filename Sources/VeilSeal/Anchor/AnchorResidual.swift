//
//  AnchorResidual.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Step 3, the warp residual at each anchor (the patent's evidence): an anchor's canonical square
//        goes through WarpResidual.batch at both strengths, unchanged, giving its fragility rate (FR)
//        and 24 keyed ordinal bits over the residual's 4×4 cells — how this neighbourhood's own texture
//        answers being warped and warped back.
//  PIN:  Squares are 32×32 RGB 0–255, exactly the tiles FragilityGrid feeds (so an aligned square's FR
//        is that tile's FR), chunked by WarpConstants.evalTileBudget, tables WarpTables.shared(true), as FragilityGrid reads.
//        Cell energy is the mean |R| of the high-strength residual over 8×8 pixels; bit n says cell
//        p < cell q for the n-th pair drawn from "burgundy/1/residual" (distinct cells).
//  ROBUSTNESS: under measurement (A7) — the residual is resampled at the anchor's scale, so a resize
//        meets the same 32 px square; how much it adds to a match is ablation C.
//

import Foundation
import MLX

public struct AnchorResidualRead: Sendable {
    public var fragility: [Float]
    /// 24 bits each, the first pair in bit 23.
    public var bits: [UInt32]
}

public enum AnchorResidual {
    public static let pairs = 24
    static let cells = 4

    /// The cell pairs a key orders.
    static func cellPairs(_ key: SealKey) -> [(Int, Int)] {
        var stream = key.stream("residual")
        var out: [(Int, Int)] = []
        while out.count < pairs {
            let p = stream.below(cells * cells), q = stream.below(cells * cells)
            if p != q { out.append((p, q)) }
        }
        return out
    }

    /// FR and residual bits for `count` squares (count × 3072 floats, 0–255).
    public static func read(_ squares: [Float], count: Int, key: SealKey) -> AnchorResidualRead {
        guard count > 0 else { return AnchorResidualRead(fragility: [], bits: []) }
        let ts = WarpConstants.tileSize
        let tables = WarpTables.shared(quantizeLikeCV2: true)
        let all = MLXArray(squares, [count, ts * ts, 3])
        let order = cellPairs(key)
        var fragility: [Float] = []
        var bits: [UInt32] = []
        fragility.reserveCapacity(count)
        bits.reserveCapacity(count)
        var a = 0
        while a < count {
            let b = min(a + WarpConstants.evalTileBudget, count)
            let chunk = all[a..<b]
            let low = WarpResidual.batch(chunk, forward: tables.lowForward, back: tables.lowBack)
            let high = WarpResidual.batch(chunk, forward: tables.highForward, back: tables.highBack)
            let fr = WarpResidual.fragility(low: low, high: high)
            let side = ts / cells
            let energy = MLX.abs(high).reshaped([b - a, cells, side, cells, side]).mean(axes: [2, 4]).reshaped([b - a, cells * cells])
            MLX.eval(fr, energy)
            fragility += fr.asArray(Float.self)
            let e = energy.asArray(Float.self)
            for n in 0..<(b - a) {
                var word: UInt32 = 0
                for (k, (p, q)) in order.enumerated() where e[n * 16 + p] < e[n * 16 + q] {
                    word |= 1 << UInt32(pairs - 1 - k)
                }
                bits.append(word)
            }
            a = b
        }
        return AnchorResidualRead(fragility: fragility, bits: bits)
    }
}
