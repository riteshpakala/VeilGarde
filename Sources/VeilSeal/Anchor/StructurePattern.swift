//
//  StructurePattern.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A neighbourhood measure that reads structure, not tone: the gradient orientations of an
//        anchor's canonical square pooled into 4 × 4 cells of 8 orientation bins (128 numbers,
//        weighted by magnitude under a Gaussian window), and 256 keyed comparisons between them.
//        Each bit says which of two (cell, orientation) entries holds more edge.
//  PIN:  Lightness is HSL's, (max + min) / 2. Gradients are central differences; each votes into its
//        two nearest orientation bins and its cells bilinearly; the window's σ is half the square.
//        The vector is normalised, clipped at 0.2 and normalised again (SIFT's), so one strong edge
//        cannot carry it. Pairs come from the key stream "burgundy/1/structure", distinct entries.
//        Pointer bits: the first 8 pairs until A7 measures flip rates.
//  ROBUSTNESS: Class II · Filters, Layers — an orientation is unchanged by any monotone remapping of
//        intensity and a tint or a layer over the whole square scales every magnitude alike;
//        pooling over cells forgives the small misregistration a recapture or a blur brings.
//

import Foundation

public struct StructurePattern: NeighbourhoodMeasure {
    public let name = "structure"
    public let pointerBits: [Int]
    let pairs: [(Int, Int)]

    public init(key: SealKey) {
        var stream = key.stream(name)
        var pairs: [(Int, Int)] = []
        while pairs.count < 256 {
            let a = stream.below(128), b = stream.below(128)
            guard a != b else { continue }
            pairs.append((a, b))
        }
        self.pairs = pairs
        pointerBits = Array(0..<8)
    }

    public func code(_ square: UnsafeBufferPointer<Float>) -> Code256 {
        let side = CanonicalPatch.side
        var l = [Float](repeating: 0, count: side * side)
        for i in 0..<(side * side) {
            let r = square[3 * i], g = square[3 * i + 1], b = square[3 * i + 2]
            l[i] = (max(r, g, b) + min(r, g, b)) / 510
        }
        var hist = [Float](repeating: 0, count: 128)
        let centre = Float(side - 1) / 2, sigma = Float(side) / 2
        for v in 1..<(side - 1) {
            for u in 1..<(side - 1) {
                let dx = l[v * side + u + 1] - l[v * side + u - 1], dy = l[(v + 1) * side + u] - l[(v - 1) * side + u]
                let m = (dx * dx + dy * dy).squareRoot()
                guard m > 1e-6 else { continue }
                let du = Float(u) - centre, dv = Float(v) - centre
                let w = m * exp(-(du * du + dv * dv) / (2 * sigma * sigma))
                var o = atan2(dy, dx) / (2 * .pi) * 8
                if o < 0 { o += 8 }
                let o0 = Int(o) % 8, o1 = (o0 + 1) % 8, fo = o - Float(Int(o))
                // Cell coordinates: cell centres at 4, 12, 20, 28.
                let cu = (Float(u) - 3.5) / 8, cv = (Float(v) - 3.5) / 8
                let u0 = Int(floor(cu)), v0 = Int(floor(cv)), fu = cu - Float(u0), fv = cv - Float(v0)
                for (cy, wy) in [(v0, 1 - fv), (v0 + 1, fv)] where cy >= 0 && cy < 4 {
                    for (cx, wx) in [(u0, 1 - fu), (u0 + 1, fu)] where cx >= 0 && cx < 4 {
                        let base = (cy * 4 + cx) * 8, k = w * wy * wx
                        hist[base + o0] += k * (1 - fo)
                        hist[base + o1] += k * fo
                    }
                }
            }
        }
        Self.normalise(&hist)
        for i in 0..<128 { hist[i] = min(hist[i], 0.2) }
        Self.normalise(&hist)
        var out = Code256()
        for (n, (a, b)) in pairs.enumerated() where hist[a] < hist[b] { out.set(n) }
        return out
    }

    static func normalise(_ v: inout [Float]) {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-9 else { return }
        for i in v.indices { v[i] /= norm }
    }
}
