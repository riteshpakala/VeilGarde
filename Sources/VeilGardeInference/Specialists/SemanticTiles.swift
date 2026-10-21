//
//  SemanticTiles.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The semantic-tile map: the per-patch-token linear head on DINOv2's 16×16 token grid,
//        P(generated) per token, and the fraction of tokens above 0.5 (the semantic majority). It
//        powers the router's semantic chain.
//  PIN:  The reference's semtileMap: tokens of the PLAIN 256/224 input (no force-resize), head
//        p > 0.5 counted. Nil when the bundle has no semtile head, at zero cost (no ViT forward).
//

import CoreGraphics

enum SemanticTiles {
    static func map(_ cg: CGImage, config: InferenceConfig) -> (grid: [[Float]], majority: Float)? {
        guard let head = HeadRegistry.shared.head(.semtile, in: config.bundle),
              let toks = try? SemanticLens.patchTokens(cg, variant: config.dinoVariant) else { return nil }
        let n = toks.count, d = toks.width
        let side = Int(Double(n).squareRoot())
        var grid = [[Float]](repeating: [Float](repeating: 0, count: side), count: side)
        var gen = 0
        for t in 0..<n {
            let p = head.pAI(Array(toks.values[(t * d)..<((t + 1) * d)]))
            grid[t / side][t % side] = p
            if p > 0.5 { gen += 1 }
        }
        return (grid, Float(gen) / Float(n))
    }
}
