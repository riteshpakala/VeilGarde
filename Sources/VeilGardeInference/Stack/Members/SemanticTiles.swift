//
//  SemanticTiles.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The semantic-tiles member: the per-patch-token linear head on DINOv2's 16×16 token grid,
//        P(generated) per token, and the fraction of tokens above 0.5, the semantic majority. Its
//        p is the majority; the preview tail reads it, and the battery reads the grid.
//  PIN:  Tokens of the PLAIN 256/224 input (no force-resize), head p > 0.5 counted. No entry when
//        the bundle has no semtile head or the profile removes the semantic tiles, checked before
//        any token is computed (no ViT forward).
//

public struct SemanticTiles: StackMember {
    public let name = "semantic-tiles"

    public init() {}

    public func score(_ s: DetectionSignals) throws -> MemberOutput? {
        guard s.config.semanticResponsibility != .semanticRemoved, let head = HeadRegistry.shared.head(.semtile, in: s.config.bundle),
              let toks = try? s.patchTokens() else { return nil }
        let n = toks.count, d = toks.width
        let side = Int(Double(n).squareRoot())
        var grid = [[Float]](repeating: [Float](repeating: 0, count: side), count: side)
        var gen = 0
        for t in 0..<n {
            let p = head.pAI(Array(toks.values[(t * d)..<((t + 1) * d)]))
            grid[t / side][t % side] = p
            if p > 0.5 { gen += 1 }
        }
        let majority = Float(gen) / Float(n)
        return MemberOutput(name: name, p: majority, verdict: majority > 0.5 ? "generated" : "real",
                            fields: [Field("majority", .number(majority)), Field("grid", .grid(grid))])
    }
}
