//
//  Consensus.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Which candidate pairs agree on one way the seal's picture sits in the found one: every pair
//        proposes a similarity on its own (its two anchors' places, scales and orientations), the one
//        most pairs agree with wins, and it is refined by least squares, then by a homography when
//        enough pairs hold. The answer maps the seal's pixels into the found picture's.
//  PIN:  Deterministic: no random sampling. Proposals from the 400 closest pairs; a pair agrees with a
//        proposal when its seal anchor lands within max(3·tol, 0.08 × its distance from the proposer)
//        and its scale ratio is within 1.6× and its turn within 35°. Then three rounds of least-squares
//        similarity at tolerance tol, and, with ≥ 8 inliers, up to six rounds of a normalised DLT homography
//        (the first two at 2·tol, then while it gains), kept only when it holds more inliers than the
//        similarity and keeps the seal's corners a convex quadrilateral.
//        tol = 8 working pixels of the found picture, in its original pixels.
//  ROBUSTNESS: Class I · Crop, Resizing; Class II · Photo of a photo — the similarity carries a crop,
//        resize and turn; the homography a photo of the picture taken at an angle.
//

import Foundation

/// A 3×3 projective map, row-major: (x, y) → ((h0 x + h1 y + h2) / w, (h3 x + h4 y + h5) / w), w = h6 x + h7 y + h8.
public struct SealTransform: Codable, Sendable, Equatable {
    public var h: [Double]

    public static let identity = SealTransform(h: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    public func apply(_ x: Double, _ y: Double) -> (Double, Double) {
        let w = h[6] * x + h[7] * y + h[8]
        return ((h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w)
    }

    /// The scale it applies near (x, y): √|det| of its local linear part.
    public func scale(at x: Double = 0, _ y: Double = 0) -> Double {
        let e = 1.0
        let o = apply(x, y), px = apply(x + e, y), py = apply(x, y + e)
        let det = (px.0 - o.0) * (py.1 - o.1) - (px.1 - o.1) * (py.0 - o.0)
        return abs(det).squareRoot()
    }

    public var inverse: SealTransform? {
        let a = h
        let c00 = a[4] * a[8] - a[5] * a[7], c01 = a[5] * a[6] - a[3] * a[8], c02 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c00 + a[1] * c01 + a[2] * c02
        guard abs(det) > 1e-12 else { return nil }
        let inv = [
            c00, a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
            c01, a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
            c02, a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3],
        ].map { $0 / det }
        return SealTransform(h: inv)
    }

    static func similarity(scale s: Double, angle t: Double, tx: Double, ty: Double) -> SealTransform {
        SealTransform(h: [s * cos(t), -s * sin(t), tx, s * sin(t), s * cos(t), ty, 0, 0, 1])
    }
}

struct ConsensusResult: Sendable {
    var transform: SealTransform
    var inliers: [Correspondence]
    var projective: Bool
}

enum Consensus {
    static let proposals = 400
    static let scaleSlack = 1.6
    static let turnSlack = 35.0 * Double.pi / 180

    static func fit(_ pairs: [Correspondence], seal: [Anchor], query: [Anchor], tolerance tol: Double) -> ConsensusResult? {
        guard pairs.count >= 3 else { return nil }
        func proposal(_ c: Correspondence) -> (SealTransform, Double, Double) {
            let a = seal[c.seal], b = query[c.query]
            let s = Double(b.scale / a.scale), t = Double(b.angle - a.angle)
            let cs = s * cos(t), sn = s * sin(t)
            let tx = Double(b.x) - (cs * Double(a.x) - sn * Double(a.y)), ty = Double(b.y) - (sn * Double(a.x) + cs * Double(a.y))
            return (SealTransform(h: [cs, -sn, tx, sn, cs, ty, 0, 0, 1]), s, t)
        }
        var bestSet: [Correspondence] = []
        for p in pairs.prefix(proposals) {
            let (m, s, t) = proposal(p)
            let origin = seal[p.seal]
            var set: [Correspondence] = []
            for c in pairs {
                let a = seal[c.seal], b = query[c.query]
                let ratio = Double(b.scale / a.scale) / s
                guard ratio < scaleSlack, ratio > 1 / scaleSlack else { continue }
                var turn = Double(b.angle - a.angle) - t
                while turn > .pi { turn -= 2 * .pi }
                while turn < -.pi { turn += 2 * .pi }
                guard abs(turn) < turnSlack else { continue }
                let (x, y) = m.apply(Double(a.x), Double(a.y))
                let reach = hypot(Double(a.x - origin.x), Double(a.y - origin.y)) * s
                guard hypot(x - Double(b.x), y - Double(b.y)) <= max(3 * tol, 0.08 * reach) else { continue }
                set.append(c)
            }
            if set.count > bestSet.count { bestSet = set }
        }
        guard bestSet.count >= 3 else { return nil }
        var transform = leastSquaresSimilarity(bestSet, seal: seal, query: query) ?? .identity
        var inliers = bestSet
        for _ in 0..<3 {
            inliers = within(pairs, transform, seal: seal, query: query, tol: tol)
            guard inliers.count >= 3, let refit = leastSquaresSimilarity(inliers, seal: seal, query: query) else { break }
            transform = refit
        }
        inliers = within(pairs, transform, seal: seal, query: query, tol: tol)
        var projective = false
        if inliers.count >= 8 {
            var h = transform, held = inliers
            for round in 0..<6 {
                guard let fitted = homography(held, seal: seal, query: query) else { break }
                let next = within(pairs, fitted, seal: seal, query: query, tol: round < 2 ? 2 * tol : tol)
                guard next.count >= 8, round < 2 || next.count > held.count else { break }
                h = fitted
                held = next
            }
            held = within(pairs, h, seal: seal, query: query, tol: tol)
            if held.count > inliers.count, h != transform, keepsConvex(h, seal: seal) {
                transform = h
                inliers = held
                projective = true
            }
        }
        return ConsensusResult(transform: transform, inliers: inliers, projective: projective)
    }

    static func within(_ pairs: [Correspondence], _ m: SealTransform, seal: [Anchor], query: [Anchor], tol: Double) -> [Correspondence] {
        pairs.filter { c in
            let a = seal[c.seal], b = query[c.query]
            let (x, y) = m.apply(Double(a.x), Double(a.y))
            return hypot(x - Double(b.x), y - Double(b.y)) <= tol
        }
    }

    /// x' = p x − q y + tx, y' = q x + p y + ty, by least squares.
    static func leastSquaresSimilarity(_ set: [Correspondence], seal: [Anchor], query: [Anchor]) -> SealTransform? {
        let n = Double(set.count)
        guard n >= 2 else { return nil }
        var mx = 0.0, my = 0.0, nx = 0.0, ny = 0.0
        for c in set {
            mx += Double(seal[c.seal].x)
            my += Double(seal[c.seal].y)
            nx += Double(query[c.query].x)
            ny += Double(query[c.query].y)
        }
        mx /= n; my /= n; nx /= n; ny /= n
        var sxx = 0.0, sp = 0.0, sq = 0.0
        for c in set {
            let ax = Double(seal[c.seal].x) - mx, ay = Double(seal[c.seal].y) - my
            let bx = Double(query[c.query].x) - nx, by = Double(query[c.query].y) - ny
            sxx += ax * ax + ay * ay
            sp += ax * bx + ay * by
            sq += ax * by - ay * bx
        }
        guard sxx > 1e-9 else { return nil }
        let p = sp / sxx, q = sq / sxx
        return SealTransform(h: [p, -q, nx - (p * mx - q * my), q, p, ny - (q * mx + p * my), 0, 0, 1])
    }

    /// Normalised DLT with h8 = 1, solved by the normal equations.
    static func homography(_ set: [Correspondence], seal: [Anchor], query: [Anchor]) -> SealTransform? {
        guard set.count >= 4 else { return nil }
        func normaliser(_ points: [(Double, Double)]) -> (Double, Double, Double) {
            let n = Double(points.count)
            let cx = points.reduce(0) { $0 + $1.0 } / n, cy = points.reduce(0) { $0 + $1.1 } / n
            let mean = points.reduce(0) { $0 + hypot($1.0 - cx, $1.1 - cy) } / n
            return (cx, cy, mean > 1e-9 ? 2.0.squareRoot() / mean : 1)
        }
        let src = set.map { (Double(seal[$0.seal].x), Double(seal[$0.seal].y)) }
        let dst = set.map { (Double(query[$0.query].x), Double(query[$0.query].y)) }
        let (sx, sy, ss) = normaliser(src), (dx, dy, ds) = normaliser(dst)
        var ata = [Double](repeating: 0, count: 64), atb = [Double](repeating: 0, count: 8)
        for k in 0..<set.count {
            let x = (src[k].0 - sx) * ss, y = (src[k].1 - sy) * ss
            let u = (dst[k].0 - dx) * ds, v = (dst[k].1 - dy) * ds
            let rows: [([Double], Double)] = [([x, y, 1, 0, 0, 0, -x * u, -y * u], u), ([0, 0, 0, x, y, 1, -x * v, -y * v], v)]
            for (r, b) in rows {
                for i in 0..<8 {
                    atb[i] += r[i] * b
                    for j in 0..<8 { ata[i * 8 + j] += r[i] * r[j] }
                }
            }
        }
        guard let hn = solve(ata, atb, 8) else { return nil }
        let normalized = SealTransform(h: hn + [1])
        // H = T_dst⁻¹ · Hn · T_src
        let tSrc = [ss, 0, -ss * sx, 0, ss, -ss * sy, 0, 0, 1]
        let tDstInv = [1 / ds, 0, dx, 0, 1 / ds, dy, 0, 0, 1]
        let h = multiply(tDstInv, multiply(normalized.h, tSrc))
        guard abs(h[8]) > 1e-12 else { return nil }
        return SealTransform(h: h.map { $0 / h[8] })
    }

    static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                out[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j]
            }
        }
        return out
    }

    /// Gaussian elimination with partial pivoting.
    static func solve(_ a: [Double], _ b: [Double], _ n: Int) -> [Double]? {
        var m = a, v = b
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(m[r * n + col]) > abs(m[pivot * n + col]) { pivot = r }
            guard abs(m[pivot * n + col]) > 1e-12 else { return nil }
            if pivot != col {
                for k in 0..<n { m.swapAt(col * n + k, pivot * n + k) }
                v.swapAt(col, pivot)
            }
            for r in 0..<n where r != col {
                let f = m[r * n + col] / m[col * n + col]
                guard f != 0 else { continue }
                for k in col..<n { m[r * n + k] -= f * m[col * n + k] }
                v[r] -= f * v[col]
            }
        }
        return (0..<n).map { v[$0] / m[$0 * n + $0] }
    }

    /// The seal's bounding box of anchors maps to a convex quadrilateral (no fold, no flip).
    static func keepsConvex(_ m: SealTransform, seal: [Anchor]) -> Bool {
        guard let minX = seal.map(\.x).min(), let maxX = seal.map(\.x).max(),
              let minY = seal.map(\.y).min(), let maxY = seal.map(\.y).max() else { return false }
        let corners = [(minX, minY), (maxX, minY), (maxX, maxY), (minX, maxY)].map { corner -> (Double, Double)? in
            let w = m.h[6] * Double(corner.0) + m.h[7] * Double(corner.1) + m.h[8]
            guard w > 1e-9 else { return nil }
            return m.apply(Double(corner.0), Double(corner.1))
        }
        let points = corners.compactMap { $0 }
        guard points.count == 4 else { return false }
        var sign = 0.0
        for i in 0..<4 {
            let a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4]
            let cross = (b.0 - a.0) * (c.1 - b.1) - (b.1 - a.1) * (c.0 - b.0)
            if cross == 0 { return false }
            if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
        }
        return sign > 0
    }
}
