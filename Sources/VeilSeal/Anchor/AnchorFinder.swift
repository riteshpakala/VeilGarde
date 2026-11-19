//
//  AnchorFinder.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Step 1, anchors: the neighbourhoods of a picture that reappear in a crop, a resize, a
//        re-encode or a photo of it. Each is a DoG extremum on lightness with its place, its scale and
//        the direction its neighbourhood leans (dominant gradient orientation).
//  PIN:  Extrema over 26 neighbours in DoG layers 1…s, |D| > ½·contrast/s first; refined by a quadratic
//        fit (≤ 5 moves, offset < ½), kept when |D(x̂)|·s ≥ contrast (0.03) and the principal-curvature
//        ratio is below edge (10). Orientation: 36-bin histogram of gradients within 4.5σ, weighted by
//        a Gaussian of 1.5σ, smoothed [1 4 6 4 1]; every peak ≥ 0.8 of the highest is its own anchor
//        (parabola-interpolated). Kept: the strongest `count` by |D(x̂)|, at most 2·count/64 in any cell
//        of an 8×8 grid on the first pass, the rest filled by strength; ties by place, scale, angle.
//        Angles are atan2(dy, dx) with y pointing down, the convention every canonical patch uses.
//  ROBUSTNESS: Class I · Crop, Resizing, Compression; Class II · Photo of a photo — scale-space
//        extrema and their orientation follow a similarity; the contrast floor and the edge test drop
//        the extrema a re-encode moves; the grid spreads anchors so a crop of any part keeps some.
//

import Foundation

/// One anchor, in the working picture's pixels until a seal carries it out.
struct FoundAnchor: Sendable {
    var x: Float
    var y: Float
    /// σ in working pixels.
    var sigma: Float
    var angle: Float
    var response: Float
    var octave: Int
    /// The Gaussian layer nearest its scale, in its octave.
    var layer: Int
}

enum AnchorFinder {
    static let contrast: Float = 0.03
    static let edge: Float = 10
    static let border = 5
    static let bins = 36
    static let peakRatio: Float = 0.8

    static func find(_ space: ScaleSpace, count: Int) -> [FoundAnchor] {
        var found: [FoundAnchor] = []
        let s = ScaleSpace.layers
        let threshold = 0.5 * contrast / Float(s)
        for o in 0..<space.dogs.count {
            let dog = space.dogs[o]
            let w = dog[0].width, h = dog[0].height
            guard w > 2 * border + 2, h > 2 * border + 2 else { continue }
            let offsets = [-w - 1, -w, -w + 1, -1, 1, w - 1, w, w + 1]
            for i in 1...s {
                dog[i].values.withUnsafeBufferPointer { cur in
                    dog[i - 1].values.withUnsafeBufferPointer { prev in
                        dog[i + 1].values.withUnsafeBufferPointer { next in
                            for y in border..<(h - border) {
                                for x in border..<(w - border) {
                                    let c = y * w + x
                                    let v = cur[c]
                                    guard abs(v) > threshold else { continue }
                                    if isExtremum(v, c, offsets, cur, prev, next),
                                       let refined = refine(dog, octave: o, layer: i, x: x, y: y) {
                                        for angle in orientations(space.gaussians[o][refined.layer], refined) {
                                            var a = refined.anchor
                                            a.angle = angle
                                            found.append(a)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return select(found, count: count, width: space.dogs[0][0].width, height: space.dogs[0][0].height)
    }

    @inline(__always)
    static func isExtremum(_ v: Float, _ c: Int, _ offsets: [Int], _ cur: UnsafeBufferPointer<Float>,
                           _ prev: UnsafeBufferPointer<Float>, _ next: UnsafeBufferPointer<Float>) -> Bool {
        if v > 0 {
            for d in offsets where cur[c + d] >= v { return false }
            if prev[c] >= v || next[c] >= v { return false }
            for d in offsets where prev[c + d] >= v || next[c + d] >= v { return false }
        } else {
            for d in offsets where cur[c + d] <= v { return false }
            if prev[c] <= v || next[c] <= v { return false }
            for d in offsets where prev[c + d] <= v || next[c + d] <= v { return false }
        }
        return true
    }

    struct Refined {
        var anchor: FoundAnchor
        var layer: Int
        var sigmaOctave: Float
        var xo: Float
        var yo: Float
    }

    /// The quadratic fit around (x, y) in DoG layer `layer`; nil when it wanders off, is too faint or is an edge.
    static func refine(_ dog: [Plane], octave: Int, layer: Int, x: Int, y: Int) -> Refined? {
        let s = ScaleSpace.layers
        var x = x, y = y, i = layer
        var offset = (Float(0), Float(0), Float(0))
        var gradient = (Float(0), Float(0), Float(0))
        var hxx: Float = 0, hyy: Float = 0, hxy: Float = 0
        let w = dog[0].width, h = dog[0].height
        var settled = false
        for _ in 0..<5 {
            let p = dog[i - 1], c = dog[i], n = dog[i + 1]
            let v = c.at(x, y)
            let dx = (c.at(x + 1, y) - c.at(x - 1, y)) / 2
            let dy = (c.at(x, y + 1) - c.at(x, y - 1)) / 2
            let ds = (n.at(x, y) - p.at(x, y)) / 2
            hxx = c.at(x + 1, y) + c.at(x - 1, y) - 2 * v
            hyy = c.at(x, y + 1) + c.at(x, y - 1) - 2 * v
            let hss = n.at(x, y) + p.at(x, y) - 2 * v
            hxy = (c.at(x + 1, y + 1) - c.at(x - 1, y + 1) - c.at(x + 1, y - 1) + c.at(x - 1, y - 1)) / 4
            let hxs = (n.at(x + 1, y) - n.at(x - 1, y) - p.at(x + 1, y) + p.at(x - 1, y)) / 4
            let hys = (n.at(x, y + 1) - n.at(x, y - 1) - p.at(x, y + 1) + p.at(x, y - 1)) / 4
            guard let solved = solve3([[hxx, hxy, hxs], [hxy, hyy, hys], [hxs, hys, hss]], [-dx, -dy, -ds]) else { return nil }
            offset = (solved[0], solved[1], solved[2])
            gradient = (dx, dy, ds)
            if abs(offset.0) < 0.5, abs(offset.1) < 0.5, abs(offset.2) < 0.5 {
                settled = true
                break
            }
            x += Int(offset.0.rounded())
            y += Int(offset.1.rounded())
            i += Int(offset.2.rounded())
            guard i >= 1, i <= s, x >= border, x < w - border, y >= border, y < h - border else { return nil }
        }
        guard settled else { return nil }
        let value = dog[i].at(x, y) + 0.5 * (gradient.0 * offset.0 + gradient.1 * offset.1 + gradient.2 * offset.2)
        guard abs(value) * Float(s) >= contrast else { return nil }
        let trace = hxx + hyy, det = hxx * hyy - hxy * hxy
        guard det > 0, trace * trace * edge < (edge + 1) * (edge + 1) * det else { return nil }
        let scale = Float(1 << octave)
        let sigmaOctave = ScaleSpace.sigma0 * pow(2, (Float(i) + offset.2) / Float(s))
        let xo = Float(x) + offset.0, yo = Float(y) + offset.1
        let anchor = FoundAnchor(x: xo * scale, y: yo * scale, sigma: sigmaOctave * scale, angle: 0, response: abs(value),
                                 octave: octave, layer: i)
        return Refined(anchor: anchor, layer: i, sigmaOctave: sigmaOctave, xo: xo, yo: yo)
    }

    /// The directions the neighbourhood leans, strongest first.
    static func orientations(_ g: Plane, _ r: Refined) -> [Float] {
        let radius = Int((4.5 * r.sigmaOctave).rounded())
        let weightSigma = 1.5 * r.sigmaOctave
        let cx = Int(r.xo.rounded()), cy = Int(r.yo.rounded())
        var histogram = [Float](repeating: 0, count: bins)
        for dy in -radius...radius {
            let y = cy + dy
            guard y > 0, y < g.height - 1 else { continue }
            for dx in -radius...radius {
                let x = cx + dx
                guard x > 0, x < g.width - 1, dx * dx + dy * dy <= radius * radius else { continue }
                let gx = g.values[y * g.width + x + 1] - g.values[y * g.width + x - 1]
                let gy = g.values[(y + 1) * g.width + x] - g.values[(y - 1) * g.width + x]
                let magnitude = (gx * gx + gy * gy).squareRoot()
                let weight = exp(-Float(dx * dx + dy * dy) / (2 * weightSigma * weightSigma))
                var angle = atan2(gy, gx)
                if angle < 0 { angle += 2 * .pi }
                let bin = Int(Float(bins) * angle / (2 * .pi)) % bins
                histogram[bin] += weight * magnitude
            }
        }
        var smooth = [Float](repeating: 0, count: bins)
        for b in 0..<bins {
            let m2 = histogram[(b + bins - 2) % bins], m1 = histogram[(b + bins - 1) % bins]
            let p1 = histogram[(b + 1) % bins], p2 = histogram[(b + 2) % bins]
            smooth[b] = (m2 + p2) / 16 + 4 * (m1 + p1) / 16 + 6 * histogram[b] / 16
        }
        guard let highest = smooth.max(), highest > 0 else { return [] }
        var peaks: [(Float, Float)] = []
        for b in 0..<bins {
            let l = smooth[(b + bins - 1) % bins], c = smooth[b], rr = smooth[(b + 1) % bins]
            guard c > l, c > rr, c >= peakRatio * highest else { continue }
            var bin = Float(b) + 0.5 * (l - rr) / (l - 2 * c + rr)
            if bin < 0 { bin += Float(bins) }
            if bin >= Float(bins) { bin -= Float(bins) }
            var angle = 2 * Float.pi * (bin + 0.5) / Float(bins)
            if angle >= 2 * .pi { angle -= 2 * .pi }
            peaks.append((c, angle))
        }
        return peaks.sorted { $0.0 > $1.0 }.map(\.1)
    }

    /// The strongest `count`, spread over an 8×8 grid on a first pass.
    static func select(_ all: [FoundAnchor], count: Int, width: Int, height: Int) -> [FoundAnchor] {
        let ranked = all.sorted {
            if $0.response != $1.response { return $0.response > $1.response }
            if $0.y != $1.y { return $0.y < $1.y }
            if $0.x != $1.x { return $0.x < $1.x }
            if $0.sigma != $1.sigma { return $0.sigma < $1.sigma }
            return $0.angle < $1.angle
        }
        guard ranked.count > count else { return ranked }
        let cells = 8, cap = max(1, 2 * count / (cells * cells))
        var used = [Int](repeating: 0, count: cells * cells)
        var taken = [Bool](repeating: false, count: ranked.count)
        var out: [FoundAnchor] = []
        out.reserveCapacity(count)
        for (n, a) in ranked.enumerated() where out.count < count {
            let cx = min(cells - 1, Int(a.x) * cells / max(1, width)), cy = min(cells - 1, Int(a.y) * cells / max(1, height))
            let cell = cy * cells + cx
            guard used[cell] < cap else { continue }
            used[cell] += 1
            taken[n] = true
            out.append(a)
        }
        for (n, a) in ranked.enumerated() where out.count < count && !taken[n] { out.append(a) }
        return out
    }

    /// Cramer's rule; nil when singular.
    static func solve3(_ m: [[Float]], _ b: [Float]) -> [Float]? {
        func det(_ a: [[Float]]) -> Float {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        guard abs(d) > 1e-12 else { return nil }
        var out: [Float] = []
        for c in 0..<3 {
            var r = m
            for row in 0..<3 { r[row][c] = b[row] }
            out.append(det(r) / d)
        }
        return out
    }
}
