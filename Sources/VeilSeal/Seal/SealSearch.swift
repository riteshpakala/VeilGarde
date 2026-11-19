//
//  SealSearch.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: How strongly one stored seal reads in a found picture: patterns matched (PatternIndex), the
//        transform most pairs agree on (Consensus), the seal's paths walked again (PathRetracer), and
//        how much of the original the found picture holds (coverage).
//  PIN:  Found when inliers ≥ foundInliers (12), retraced hops ≥ foundHops (3) and the shared anchors
//        sit in at least foundCells (4) cells of an 8×8 grid over the original. The spread is the
//        guard against a shared overlay: two different photos stamped with the same caption agreed
//        on 24 anchors of identical rendered letters, all in one or two cells (ISS frames, 2026-11-19);
//        a quarter crop spreads over about 16. And agreement ≥ foundAgreement (0.15): the shared anchors
//        are at least that share of the seal's anchors the transform puts inside the found picture at a
//        scale it can still see (σ ≥ σ0 of its working picture). Screenshots of one app share its frame
//        (status bar, buttons, nav bar) over 11–16 cells at 7%; two reels with the same stickers at
//        11–12%; a true copy under any of the 28 changes holds 19% or more (seed 1, 2026-11-19). Coverage
//        samples the original on a 32×32 grid and counts the points the transform puts inside the
//        found picture. Tolerance: 8 of the found picture's working pixels.
//

import Foundation

public enum SealSearch {
    public static let foundInliers = 12
    public static let foundHops = 3
    public static let foundCells = 4
    public static let foundAgreement = 0.15

    static func score(_ record: SealRecord, in reading: AnchorReading, pointerBits: [Int]) -> SealMatch? {
        let pairs = PatternIndex.match(query: reading.anchors, seal: record.anchors)
        let tolerance = 8 * reading.toOriginal
        guard let fit = Consensus.fit(pairs, seal: record.anchors, query: reading.anchors, tolerance: tolerance) else { return nil }
        let trace = PathRetracer.retrace(record.paths, seal: record.anchors, query: reading.anchors, inliers: fit.inliers,
                                         pointerBits: pointerBits)
        let m = fit.transform
        let w = Double(record.image.width), h = Double(record.image.height)
        var inside = 0
        for gy in 0..<32 {
            for gx in 0..<32 {
                let (x, y) = m.apply((Double(gx) + 0.5) * w / 32, (Double(gy) + 0.5) * h / 32)
                if x >= 0, y >= 0, x < Double(reading.width), y < Double(reading.height) { inside += 1 }
            }
        }
        let finest = Double(ScaleSpace.sigma0) * reading.toOriginal
        var visible = 0
        for a in record.anchors {
            let (x, y) = m.apply(Double(a.x), Double(a.y))
            guard x >= 0, y >= 0, x < Double(reading.width), y < Double(reading.height),
                  Double(a.scale) * m.scale(at: Double(a.x), Double(a.y)) >= finest else { continue }
            visible += 1
        }
        let agreement = visible > 0 ? min(1, Double(fit.inliers.count) / Double(visible)) : 0
        var agree = 0, compared = 0
        for c in fit.inliers {
            guard let a = record.anchors[c.seal].residual, let b = reading.anchors[c.query].residual else { continue }
            agree += AnchorResidual.pairs - Int((a ^ b).nonzeroBitCount)
            compared += AnchorResidual.pairs
        }
        var partner = [Int: Int]()
        for c in fit.inliers { partner[c.seal] = c.query }
        let trails = zip(record.paths, trace.hops).compactMap { path, hops -> SealTrail? in
            let points = path.anchors.map { i in partner[i].map { SealPoint(Double(reading.anchors[$0].x), Double(reading.anchors[$0].y)) } }
            return points.contains { $0 != nil } ? SealTrail(points: points, retraced: hops) : nil
        }
        var occupied = Set<Int>()
        for c in fit.inliers {
            let a = record.anchors[c.seal]
            occupied.insert(min(7, max(0, Int(8 * Double(a.x) / w))) * 8 + min(7, max(0, Int(8 * Double(a.y) / h))))
        }
        let found = fit.inliers.count >= foundInliers && trace.retraced >= foundHops && occupied.count >= foundCells
            && agreement >= foundAgreement
        return SealMatch(
            id: record.id, label: record.label, createdAt: record.createdAt, candidates: pairs.count, inliers: fit.inliers.count,
            retraced: trace.retraced, possible: trace.possible, coverage: Double(inside) / 1024, cells: occupied.count, agreement: agreement, scale: m.scale(at: w / 2, h / 2),
            projective: fit.projective, residualAgreement: compared > 0 ? Double(agree) / Double(compared) : nil, transform: m, found: found,
            anchors: fit.inliers.map { SealPoint(Double(reading.anchors[$0.query].x), Double(reading.anchors[$0.query].y)) },
            trails: trails,
            portion: [(0.0, 0.0), (w, 0), (w, h), (0, h)].map { SealPoint(m.apply($0.0, $0.1).0, m.apply($0.0, $0.1).1) })
    }

    /// The strongest reading among `records`: found ones first, then by inliers.
    static func best(_ records: [SealRecord], score: (SealRecord) -> SealMatch?) -> SealMatch? {
        var best: SealMatch?
        for record in records {
            guard let m = score(record) else { continue }
            if let b = best, (b.found ? 1 : 0, b.inliers, b.retraced) >= (m.found ? 1 : 0, m.inliers, m.retraced) { continue }
            best = m
        }
        return best
    }
}
