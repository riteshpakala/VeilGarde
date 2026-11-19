//
//  CensusPattern.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A neighbourhood measure that reads each colour channel on its own: 256 keyed comparisons
//        between smoothed points of an anchor's canonical square, a third in red, a third in green, a
//        third in blue. A layer blended over the square in normal, multiply, screen or overlay, a warm
//        curve, a gamma or a contrast remaps each channel monotonically, and keeps every bit.
//  PIN:  The square is smoothed 3×3 (box, edges extended). Points from the key stream
//        "burgundy/1/census", inside radius 15, at least 3 apart; comparison n reads channel n mod 3.
//        Pointer bits: the 8 comparisons furthest apart, until A7 measures flip rates.
//  ROBUSTNESS: Class II · Layers, Filters (warm, gamma, contrast) — a per-channel monotone change
//        keeps the order of any two points in that channel; hue turns and grayscale, which mix the
//        channels, are what it gives up.
//

import Foundation

public struct CensusPattern: NeighbourhoodMeasure {
    public let name = "census"
    public let pointerBits: [Int]
    let pairs: [(Int, Int)]

    public init(key: SealKey) {
        var stream = key.stream(name)
        let side = CanonicalPatch.side
        let centre = Float(side - 1) / 2
        var pairs: [(Int, Int)] = []
        var separation: [Float] = []
        while pairs.count < 256 {
            let p = (stream.below(side), stream.below(side)), q = (stream.below(side), stream.below(side))
            func inside(_ t: (Int, Int)) -> Bool {
                let dx = Float(t.0) - centre, dy = Float(t.1) - centre
                return dx * dx + dy * dy <= 225
            }
            let dx = Float(p.0 - q.0), dy = Float(p.1 - q.1)
            let apart = (dx * dx + dy * dy).squareRoot()
            guard inside(p), inside(q), apart >= 3 else { continue }
            pairs.append((p.1 * side + p.0, q.1 * side + q.0))
            separation.append(apart)
        }
        self.pairs = pairs
        pointerBits = Array((0..<256).sorted { separation[$0] != separation[$1] ? separation[$0] > separation[$1] : $0 < $1 }.prefix(8))
    }

    public func code(_ square: UnsafeBufferPointer<Float>) -> Code256 {
        let side = CanonicalPatch.side, count = side * side
        var smooth = [Float](repeating: 0, count: count * 3)
        for v in 0..<side {
            for u in 0..<side {
                var acc: (Float, Float, Float) = (0, 0, 0)
                for dv in -1...1 {
                    let vv = min(max(v + dv, 0), side - 1)
                    for du in -1...1 {
                        let i = (vv * side + min(max(u + du, 0), side - 1)) * 3
                        acc.0 += square[i]
                        acc.1 += square[i + 1]
                        acc.2 += square[i + 2]
                    }
                }
                let o = (v * side + u) * 3
                smooth[o] = acc.0
                smooth[o + 1] = acc.1
                smooth[o + 2] = acc.2
            }
        }
        var out = Code256()
        for (n, (p, q)) in pairs.enumerated() {
            let c = n % 3
            if smooth[3 * p + c] < smooth[3 * q + c] { out.set(n) }
        }
        return out
    }
}
