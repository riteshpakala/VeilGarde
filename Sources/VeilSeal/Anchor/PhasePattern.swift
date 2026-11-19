//
//  PhasePattern.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A neighbourhood measure that reads phase, not amplitude: 128 keyed Gabor filters over an
//        anchor's canonical square (lightness), each giving two bits, the signs of its even and odd
//        responses. Structure lives in phase; a brightness shift, a contrast change or a layer over
//        the whole square lives in amplitude and the mean, which the signs of zero-mean filters ignore.
//  PIN:  Filters drawn from the key stream "burgundy/1/phase": a centre within radius 9 of the
//        square's, a wavelength of 6, 9 or 14 px, an orientation in [0, π), envelope σ = 0.5 λ, cut at
//        2.5 σ inside the square. Each kernel has its mean removed, so a constant adds nothing.
//        Bits 2k and 2k+1 are filter k's even and odd signs. Pointer bits: the even bits of the 8
//        longest wavelengths nearest the centre, until A7 measures flip rates.
//  ROBUSTNESS: Class II · Filters (brightness, contrast), Layers — signs of zero-mean responses are
//        unchanged by adding to or scaling the square; long wavelengths forgive blur and recapture.
//

import Foundation

public struct PhasePattern: NeighbourhoodMeasure {
    public let name = "phase"
    public let pointerBits: [Int]
    /// Per filter: pixel indices and the even and odd weights.
    let filters: [(index: [Int32], even: [Float], odd: [Float])]

    public init(key: SealKey) {
        var stream = key.stream(name)
        let side = CanonicalPatch.side
        let centre = Float(side - 1) / 2
        let wavelengths: [Float] = [6, 9, 14]
        var filters: [(index: [Int32], even: [Float], odd: [Float])] = []
        var rank: [(Float, Float, Int)] = []
        while filters.count < 128 {
            let cx = Float(stream.below(19)) - 9 + centre, cy = Float(stream.below(19)) - 9 + centre
            guard (cx - centre) * (cx - centre) + (cy - centre) * (cy - centre) <= 81 else { continue }
            let lambda = wavelengths[stream.below(3)]
            let theta = Float(stream.below(180)) * .pi / 180
            let sigma = 0.5 * lambda, reach = 2.5 * sigma
            var index: [Int32] = [], even: [Float] = [], odd: [Float] = []
            for v in 0..<side {
                for u in 0..<side {
                    let dx = Float(u) - cx, dy = Float(v) - cy
                    guard dx * dx + dy * dy <= reach * reach else { continue }
                    let g = exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
                    let t = 2 * .pi * (dx * cos(theta) + dy * sin(theta)) / lambda
                    index.append(Int32(v * side + u))
                    even.append(g * cos(t))
                    odd.append(g * sin(t))
                }
            }
            let me = even.reduce(0, +) / Float(even.count), mo = odd.reduce(0, +) / Float(odd.count)
            filters.append((index, even.map { $0 - me }, odd.map { $0 - mo }))
            rank.append((lambda, (cx - centre) * (cx - centre) + (cy - centre) * (cy - centre), filters.count - 1))
        }
        self.filters = filters
        pointerBits = rank.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }.prefix(8).map { 2 * $0.2 }
    }

    public func code(_ square: UnsafeBufferPointer<Float>) -> Code256 {
        let side = CanonicalPatch.side
        var l = [Float](repeating: 0, count: side * side)
        for i in 0..<(side * side) {
            let r = square[3 * i], g = square[3 * i + 1], b = square[3 * i + 2]
            l[i] = (max(r, g, b) + min(r, g, b)) / 510
        }
        var out = Code256()
        for (k, f) in filters.enumerated() {
            var e: Float = 0, o: Float = 0
            for n in 0..<f.index.count {
                let x = l[Int(f.index[n])]
                e += f.even[n] * x
                o += f.odd[n] * x
            }
            if e > 0 { out.set(2 * k) }
            if o > 0 { out.set(2 * k + 1) }
        }
        return out
    }
}
