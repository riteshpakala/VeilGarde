//
//  FragilityObjective.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What the embedder minimises on one tile grid, and its gradient in the pixels. For every pair
//        of 8-neighbour tiles whose levels differ, softplus(β(μ − (g₊ − g₋)))/β with g = log(FR + 0.05):
//        the +1 tile's fragility is pushed above the −1 tile's by μ in log terms, so the ordinal tile
//        codes carry the levels. The chain rule is split: the host turns each tile's fragility into
//        ∂L/∂FR, and MLX differentiates Σ c_t·FR_t through the warp residual into the pixels.
//  PIN:  A tile's fragility reads its own 32 × 32 pixels only, so on the embedding grid each tile's
//        gradient stays inside it (within ~12 px of its edges, where the high-pass mean lives). The
//        luma offset is added to R, G and B alike, so its gradient is the three channels' sum. Tiles
//        whose coefficient is zero are not differentiated at all; chunks hold at most 64 tiles. MLX's
//        gradients are not bit-reproducible, so nothing pins the pixels an embed writes.
//

import Foundation
import MLX
import MLXAccelerate

struct FragilityObjective {
    struct Pair {
        var plus: Int32
        var minus: Int32
        var active = true
    }

    static let floor: Float = 0.05

    let rows: Int
    let cols: Int
    /// A repair round raises it; the pairs taken out stay out.
    var margin: Float
    let weight: Float
    let sharpness: Float
    private(set) var pairs: [Pair] = []

    /// `levels` is row-major over rows × cols, each ±1.
    init(levels: [Int8], rows: Int, cols: Int, margin: Float, weight: Float, sharpness: Float) {
        self.rows = rows
        self.cols = cols
        self.margin = margin
        self.weight = weight
        self.sharpness = sharpness
        for r in 0..<rows {
            for c in 0..<cols {
                let a = r * cols + c
                for (dr, dc) in TileCodeGrid.neighbours {
                    let nr = r + dr, nc = c + dc
                    guard nr >= 0, nr < rows, nc >= 0, nc < cols else { continue }
                    let b = nr * cols + nc
                    guard levels[a] != levels[b] else { continue }
                    pairs.append(levels[a] > 0 ? Pair(plus: Int32(a), minus: Int32(b)) : Pair(plus: Int32(b), minus: Int32(a)))
                }
            }
        }
    }

    @inline(__always) static func g(_ fr: Float) -> Float { Foundation.log(Swift.max(fr, 0) + floor) }
    @inline(__always) static func dg(_ fr: Float) -> Float { fr >= 0 ? 1 / (fr + floor) : 0 }

    struct Evaluation {
        var loss: Float
        /// ∂L/∂FR per tile.
        var coefficients: [Float]
        var satisfied: Int
        var active: Int
        var share: Double { active > 0 ? Double(satisfied) / Double(active) : 1 }
    }

    func evaluate(_ fr: [Float]) -> Evaluation {
        var coefficients = [Float](repeating: 0, count: rows * cols)
        var loss: Float = 0
        var satisfied = 0, active = 0
        for pair in pairs where pair.active {
            active += 1
            let p = Int(pair.plus), m = Int(pair.minus)
            let gap = Self.g(fr[p]) - Self.g(fr[m])
            if gap >= margin { satisfied += 1 }
            let x = sharpness * (margin - gap)
            loss += weight * (x > 20 ? x : Foundation.log1p(Foundation.exp(x))) / sharpness
            let s = weight / (1 + Foundation.exp(-x))     // σ(x)
            coefficients[p] -= s * Self.dg(fr[p])
            coefficients[m] += s * Self.dg(fr[m])
        }
        return Evaluation(loss: loss, coefficients: coefficients, satisfied: satisfied, active: active)
    }

    /// Takes out the pairs still short of their gap by more than `factor` margins; returns how many.
    @discardableResult
    mutating func dropHopeless(_ fr: [Float], factor: Float) -> Int {
        var dropped = 0
        for i in pairs.indices where pairs[i].active {
            let gap = Self.g(fr[Int(pairs[i].plus)]) - Self.g(fr[Int(pairs[i].minus)])
            if margin - gap > factor * margin {
                pairs[i].active = false
                dropped += 1
            }
        }
        return dropped
    }
}

enum FragilityGradient {
    static let chunk = 64

    /// Adds ∂(Σ c_t·FR_t)/∂(luma offset) for the rows × cols tiles from (originX, originY) of `plane`
    /// ([H, W, 3]) into `gradient` (row-major H × W, `width` wide). Tiles with c_t = 0 are skipped.
    static func accumulate(_ plane: MLXArray, originX: Int, originY: Int, rows: Int, cols: Int, coefficients: [Float],
                           width: Int, into gradient: inout [Float]) {
        let ts = WarpConstants.tileSize
        let tables = WarpTables.shared(quantizeLikeCV2: true)
        let all = TileReads.tiles(plane, originX: originX, originY: originY, rows: rows, cols: cols)
        let live = coefficients.indices.filter { coefficients[$0] != 0 }
        var start = 0
        while start < live.count {
            let picked = Array(live[start..<min(start + chunk, live.count)])
            start += picked.count
            let base = all.take(MLXArray(picked.map { Int32($0) }), axis: 0)
            let c = MLXArray(picked.map { coefficients[$0] })
            let f: ([MLXArray]) -> [MLXArray] = { args in
                let x = base + args[0].expandedDimensions(axis: 2)
                let low = WarpResidual.batch(x, forward: tables.lowForward, back: tables.lowBack)
                let high = WarpResidual.batch(x, forward: tables.highForward, back: tables.highBack)
                return [(WarpResidual.fragility(low: low, high: high) * c).sum()]
            }
            let (_, grads) = valueAndGrad(f)([MLXArray.zeros([picked.count, ts * ts])])
            let g = grads[0]
            MLX.eval(g)
            let host = g.asArray(Float.self)
            for (k, tile) in picked.enumerated() {
                let r = tile / cols, cc = tile % cols
                let y0 = originY + r * ts, x0 = originX + cc * ts
                for i in 0..<ts {
                    let row = (y0 + i) * width + x0
                    let src = k * ts * ts + i * ts
                    for j in 0..<ts { gradient[row + j] += host[src + j] }
                }
            }
        }
    }
}
