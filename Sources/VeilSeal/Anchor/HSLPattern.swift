//
//  HSLPattern.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The first neighbourhood measure: 256 keyed comparisons between points of an anchor's canonical
//        square, read in HSL — 192 on lightness, 32 on saturation, 32 on hue. Each bit says which of two
//        points is lighter (more saturated, further round the hue circle), so a tone curve that keeps
//        order keeps the bits; a tint or a hue layer is what it is still to be measured against.
//  PIN:  The square is smoothed 3×3 (box, edges extended) in RGB before HSL. Points are drawn from the
//        key stream "burgundy/1/hsl" inside the circle of radius 15 about (15.5, 15.5), at least 3 apart.
//        Hue bits are the sign of sin 2π(Hp − Hq). Pointer bits: the 8 lightness pairs furthest apart,
//        the furthest first (A7 replaces them by measured flip rates).
//  ROBUSTNESS: Class I · Compression; Class II · Filters (brightness, contrast, gamma) — ordinal
//        comparisons of smoothed points ignore any monotone change of lightness and most re-encoding.
//

import Foundation

public struct HSLPattern: NeighbourhoodMeasure {
    public static let lightnessPairs = 192
    public static let saturationPairs = 32
    public static let huePairs = 32

    public let name = "hsl"
    public let pointerBits: [Int]
    /// Pixel indices (v·32 + u) of each comparison's two points.
    let pairs: [(Int, Int)]

    public init(key: SealKey) {
        var stream = key.stream(name)
        let side = CanonicalPatch.side
        let centre = Float(side - 1) / 2
        var pairs: [(Int, Int)] = []
        var separation: [Float] = []
        while pairs.count < Self.lightnessPairs + Self.saturationPairs + Self.huePairs {
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
        pointerBits = Array((0..<Self.lightnessPairs).sorted {
            separation[$0] != separation[$1] ? separation[$0] > separation[$1] : $0 < $1
        }.prefix(8))
    }

    public func code(_ square: UnsafeBufferPointer<Float>) -> Code256 {
        let side = CanonicalPatch.side, count = side * side
        var smooth = [Float](repeating: 0, count: count * 3)
        for v in 0..<side {
            for u in 0..<side {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for dv in -1...1 {
                    let vv = min(max(v + dv, 0), side - 1)
                    for du in -1...1 {
                        let uu = min(max(u + du, 0), side - 1)
                        let i = (vv * side + uu) * 3
                        r += square[i]
                        g += square[i + 1]
                        b += square[i + 2]
                    }
                }
                let o = (v * side + u) * 3
                smooth[o] = r / 9
                smooth[o + 1] = g / 9
                smooth[o + 2] = b / 9
            }
        }
        var lightness = [Float](repeating: 0, count: count), saturation = lightness, hue = lightness
        for i in 0..<count {
            let hsl = Self.hsl(smooth[3 * i] / 255, smooth[3 * i + 1] / 255, smooth[3 * i + 2] / 255)
            lightness[i] = hsl.l
            saturation[i] = hsl.s
            hue[i] = hsl.h
        }
        var out = Code256()
        for (n, (p, q)) in pairs.enumerated() {
            let set: Bool
            if n < Self.lightnessPairs {
                set = lightness[p] < lightness[q]
            } else if n < Self.lightnessPairs + Self.saturationPairs {
                set = saturation[p] < saturation[q]
            } else {
                set = sin(2 * .pi * (hue[p] - hue[q])) > 0
            }
            if set { out.set(n) }
        }
        return out
    }

    /// HSL of one RGB 0–1: hue 0–1 (red at 0), saturation 0–1, lightness 0–1.
    static func hsl(_ r: Float, _ g: Float, _ b: Float) -> (h: Float, s: Float, l: Float) {
        let high = max(r, g, b), low = min(r, g, b)
        let l = (high + low) / 2
        let d = high - low
        guard d > 1e-6 else { return (0, 0, l) }
        let s = d / max(1e-6, 1 - abs(2 * l - 1))
        var h: Float
        if high == r {
            h = (g - b) / d
            if h < 0 { h += 6 }
        } else if high == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        return (h / 6, min(1, s), l)
    }
}
