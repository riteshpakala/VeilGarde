//
//  SealDerivation.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Whether the warp residual tells a copy of a sealed picture from another shot of the same
//        scene, where the anchors cannot: pairs of consecutive camera frames (A, B) whose anchors
//        match (B is found as A's seal: a re-shoot), A sealed with its residual, then A's changes
//        (derived) and B and B's same changes (re-shoots) read against A's seal. For each, over the
//        consensus inliers: the stored residual's bit agreement, its cell energies' correlation and
//        the fragility gap; as controls, the patterns' distance and the fit's reprojection error;
//        and the aligned residual: 32 × 32 windows of A's own pixels at its strongest inlier anchors,
//        the found picture sampled through the fitted transform onto the same windows, both through
//        the warp residual, their maps correlated.
//  PIN:  A study, not a gate: it decides nothing and writes one row per (pair, kind, change). A pair
//        whose B is not found as A's seal (inliers ≥ 12, hops ≥ 3, spread over ≥ 4 cells) is not a
//        re-shoot of it and is left out. The aligned windows are A's shared pixels (long side ≤ 2048), at most 64 per row,
//        each window's map correlated with its partner's (Pearson), the mean kept.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens

public struct SealDerivationRow: Codable, Sendable {
    public var pair: Int
    public var a: String
    public var b: String
    /// "derived" (A changed) or "reshoot" (B, changed or not).
    public var kind: String
    public var change: String
    public var inliers: Int
    public var retraced: Int
    public var coverage: Double
    /// Cells of an 8×8 grid over A holding a shared anchor (a shared caption fills one or two).
    public var cells: Int
    public var bitAgreement: Double?
    public var cellCorrelation: Double?
    public var fragilityGap: Double?
    public var codeDistance: Double
    public var reprojection: Double
    public var alignedCorrelation: Double?
    public var aligned: Int
}

public enum SealDerivation {
    public static let changes: [SealChange] = [.jpeg90, .jpeg60, .crop50, .resize75, .resize50, .brightness, .recapture]

    public static func run(pairs: [(URL, URL)], changes: [SealChange] = changes, key: SealKey = .default, longSide: Int = 2048,
                           rows rowsURL: URL?, log: @escaping @Sendable (String) -> Void) throws -> [SealDerivationRow] {
        guard let measure = NeighbourhoodMeasures.named(BurgundySeal.defaultMeasure, key: key) else { return [] }
        if let rowsURL { FileManager.default.createFile(atPath: rowsURL.path, contents: nil) }
        let writer = rowsURL.flatMap { try? FileHandle(forWritingTo: $0) }
        let lock = NSLock()
        var all: [SealDerivationRow] = []
        var done = 0, reshoots = 0
        DispatchQueue.concurrentPerform(iterations: pairs.count) { n in
            let (ua, ub) = pairs[n]
            guard let pa = try? SealAcceptance.picture(ua, longSide: longSide), let pb = try? SealAcceptance.picture(ub, longSide: longSide),
                  let ca = try? pa.cgImage(),
                  let seal = try? AnchorReading.read(ca, key: key, measure: measure, count: AnchorReading.sealCount, residual: true),
                  seal.anchors.count >= SealSearch.foundInliers
            else { return }
            let paths = PathWalker.walk(seal.anchors, pointerBits: measure.pointerBits)
            func row(_ kind: String, _ change: String, _ copy: SealPixels) -> SealDerivationRow? {
                guard let cg = try? copy.cgImage(),
                      let q = try? AnchorReading.read(cg, key: key, measure: measure, count: AnchorReading.searchCount, residual: true)
                else { return nil }
                return measureRow(n, ua, ub, kind, change, seal: seal, paths: paths, sealPixels: pa, query: q, queryPixels: copy, pointerBits: measure.pointerBits)
            }
            guard let plain = row("reshoot", "none", pb), plain.inliers >= SealSearch.foundInliers, plain.retraced >= SealSearch.foundHops,
                  plain.cells >= SealSearch.foundCells else {
                lock.lock(); done += 1; lock.unlock()
                return
            }
            var mine = [plain]
            for change in changes {
                let seed = SealAcceptance.seed(0, picture: n, change: change)
                if let a = try? change.apply(pa, seed: seed), let r = row("derived", change.rawValue, a) { mine.append(r) }
                if let b = try? change.apply(pb, seed: seed), let r = row("reshoot", change.rawValue, b) { mine.append(r) }
            }
            lock.lock()
            all += mine
            done += 1
            reshoots += 1
            if let writer { for r in mine { if let line = try? JSONEncoder().encode(r) { writer.write(line + Data("\n".utf8)) } } }
            log("\(done)/\(pairs.count) \(ua.lastPathComponent) ~ \(ub.lastPathComponent): a re-shoot (\(plain.inliers) inliers), \(reshoots) so far")
            lock.unlock()
        }
        try? writer?.close()
        return all
    }

    static func measureRow(_ n: Int, _ ua: URL, _ ub: URL, _ kind: String, _ change: String, seal: AnchorReading, paths: [SealPath],
                           sealPixels: SealPixels, query: AnchorReading, queryPixels: SealPixels, pointerBits: [Int]) -> SealDerivationRow? {
        let pairs = PatternIndex.match(query: query.anchors, seal: seal.anchors)
        let tolerance = 8 * query.toOriginal
        guard let fit = Consensus.fit(pairs, seal: seal.anchors, query: query.anchors, tolerance: tolerance) else {
            return SealDerivationRow(pair: n, a: ua.lastPathComponent, b: ub.lastPathComponent, kind: kind, change: change, inliers: 0, retraced: 0,
                                     coverage: 0, cells: 0, bitAgreement: nil, cellCorrelation: nil, fragilityGap: nil, codeDistance: 256, reprojection: 99,
                                     alignedCorrelation: nil, aligned: 0)
        }
        let trace = PathRetracer.retrace(paths, seal: seal.anchors, query: query.anchors, inliers: fit.inliers, pointerBits: pointerBits)
        let m = fit.transform
        var bits = 0.0, cells = 0.0, gap = 0.0, code = 0.0, error = 0.0
        var nb = 0, nc = 0
        for c in fit.inliers {
            let a = seal.anchors[c.seal], b = query.anchors[c.query]
            code += Double(a.code.distance(b.code))
            let (x, y) = m.apply(Double(a.x), Double(a.y))
            error += (hypot(x - Double(b.x), y - Double(b.y)) / query.toOriginal).squared
            if let ra = a.residual, let rb = b.residual {
                bits += Double(AnchorResidual.pairs - (ra ^ rb).nonzeroBitCount) / Double(AnchorResidual.pairs)
                nb += 1
            }
            if let fa = a.fragility, let fb = b.fragility, fa > 0, fb > 0 { gap += abs(log(Double(fa) / Double(fb))) }
            if let sa = seal.residualCells, let sb = query.residualCells {
                cells += pearson(Array(sa[(c.seal * 16)..<((c.seal + 1) * 16)]), Array(sb[(c.query * 16)..<((c.query + 1) * 16)]))
                nc += 1
            }
        }
        let k = Double(fit.inliers.count)
        var occupied = Set<Int>()
        for c in fit.inliers {
            let a = seal.anchors[c.seal]
            occupied.insert(min(7, max(0, Int(8 * Double(a.x) / Double(seal.width)))) * 8 + min(7, max(0, Int(8 * Double(a.y) / Double(seal.height)))))
        }
        let (aligned, count) = alignedCorrelation(fit.inliers, seal: seal, sealPixels: sealPixels, queryPixels: queryPixels, transform: m)
        let w = Double(seal.width), h = Double(seal.height)
        var inside = 0
        for gy in 0..<32 {
            for gx in 0..<32 {
                let (x, y) = m.apply((Double(gx) + 0.5) * w / 32, (Double(gy) + 0.5) * h / 32)
                if x >= 0, y >= 0, x < Double(query.width), y < Double(query.height) { inside += 1 }
            }
        }
        return SealDerivationRow(pair: n, a: ua.lastPathComponent, b: ub.lastPathComponent, kind: kind, change: change, inliers: fit.inliers.count,
                                 retraced: trace.retraced, coverage: Double(inside) / 1024, cells: occupied.count, bitAgreement: nb > 0 ? bits / Double(nb) : nil,
                                 cellCorrelation: nc > 0 ? cells / Double(nc) : nil, fragilityGap: k > 0 ? gap / k : nil, codeDistance: code / max(1, k),
                                 reprojection: (error / max(1, k)).squareRoot(), alignedCorrelation: aligned, aligned: count)
    }

    /// The warp residual of A's own 32 × 32 windows at its strongest inlier anchors against the found picture sampled onto them.
    static func alignedCorrelation(_ inliers: [Correspondence], seal: AnchorReading, sealPixels: SealPixels, queryPixels: SealPixels,
                                   transform m: SealTransform) -> (Double?, Int) {
        let side = WarpConstants.tileSize, half = Double(side) / 2
        // Seal anchors are in the sealed picture's pixels (here its shared pixels, so sx is 1); the transform maps
        // them into the found picture's pixels.
        let sx = Double(sealPixels.width) / Double(seal.width)
        let chosen = inliers.sorted { seal.anchors[$0.seal].response > seal.anchors[$1.seal].response }.prefix(64)
        var a: [Float] = [], b: [Float] = []
        var used = 0
        for c in chosen {
            let anchor = seal.anchors[c.seal]
            let cx = Double(anchor.x) * sx, cy = Double(anchor.y) * sx
            guard cx - half >= 0, cy - half >= 0, cx + half < Double(sealPixels.width), cy + half < Double(sealPixels.height) else { continue }
            var wa = [Float](repeating: 0, count: side * side * 3), wb = wa
            var ok = true
            for v in 0..<side {
                for u in 0..<side {
                    let px = Int(cx - half) + u, py = Int(cy - half) + v
                    for ch in 0..<3 { wa[(v * side + u) * 3 + ch] = Float(sealPixels.rgb[3 * (py * sealPixels.width + px) + ch]) }
                    // The same point of the original, through the transform, in the found picture's pixels.
                    let (qx, qy) = m.apply((Double(px) + 0.5) / sx, (Double(py) + 0.5) / sx)
                    let fx = qx - 0.5, fy = qy - 0.5
                    guard fx >= 0, fy >= 0, fx < Double(queryPixels.width - 1), fy < Double(queryPixels.height - 1) else { ok = false; continue }
                    let x0 = Int(fx), y0 = Int(fy), tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
                    for ch in 0..<3 {
                        let q00 = Float(queryPixels.rgb[3 * (y0 * queryPixels.width + x0) + ch])
                        let q10 = Float(queryPixels.rgb[3 * (y0 * queryPixels.width + x0 + 1) + ch])
                        let q01 = Float(queryPixels.rgb[3 * ((y0 + 1) * queryPixels.width + x0) + ch])
                        let q11 = Float(queryPixels.rgb[3 * ((y0 + 1) * queryPixels.width + x0 + 1) + ch])
                        let top = q00 + tx * (q10 - q00), bottom = q01 + tx * (q11 - q01)
                        wb[(v * side + u) * 3 + ch] = top + ty * (bottom - top)
                    }
                }
            }
            guard ok else { continue }
            a += wa
            b += wb
            used += 1
        }
        guard used > 0 else { return (nil, 0) }
        let ma = AnchorResidual.highMaps(a, count: used), mb = AnchorResidual.highMaps(b, count: used)
        let n = side * side
        var total = 0.0
        for i in 0..<used { total += pearson(Array(ma[(i * n)..<((i + 1) * n)]), Array(mb[(i * n)..<((i + 1) * n)])) }
        return (total / Double(used), used)
    }

    static func pearson(_ x: [Float], _ y: [Float]) -> Double {
        let n = Double(x.count)
        guard n > 1 else { return 0 }
        let mx = x.reduce(0) { $0 + Double($1) } / n, my = y.reduce(0) { $0 + Double($1) } / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<x.count {
            let dx = Double(x[i]) - mx, dy = Double(y[i]) - my
            sxy += dx * dy
            sxx += dx * dx
            syy += dy * dy
        }
        return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
    }
}

private extension Double {
    var squared: Double { self * self }
}
