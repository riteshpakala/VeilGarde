//
//  PathRetracer.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Step 5, retrace paths ←: walk the seal's paths again in the found picture. For each hop of a
//        seal path whose two anchors both have a partner in the found picture, the partner of the first
//        follows its own pattern's pointer among the anchors the two pictures share; the hop is retraced
//        when it lands on the partner of the second. Hops are checked one at a time, so a crop holding
//        half a path still counts the half it holds, from either end.
//  PIN:  Shared anchors are the consensus inliers. The found picture's pointer reads its own code's
//        pointer bits, its own orientation and its own σ (reach 2σ–40σ): nothing is copied from the seal
//        but which anchor is whose partner.
//  ROBUSTNESS: false-match control — a hop retraces only when the found picture's own patterns walk
//        the seal's walk; a crop keeps every hop inside it.
//

import Foundation

struct RetraceResult: Sendable {
    /// Hops retraced, and hops whose two anchors were both found.
    var retraced: Int
    var possible: Int
    /// Per path: for each hop, whether it was retraced (nil when not both anchors were found).
    var hops: [[Bool?]]
}

enum PathRetracer {
    static func retrace(_ paths: [SealPath], seal: [Anchor], query: [Anchor], inliers: [Correspondence], pointerBits: [Int]) -> RetraceResult {
        var partner = [Int: Int]()
        for c in inliers { partner[c.seal] = c.query }
        let shared = Array(Set(inliers.map(\.query))).sorted()
        let sharedAnchors = shared.map { query[$0] }
        var local = [Int: Int]()
        for (n, q) in shared.enumerated() { local[q] = n }
        var retraced = 0, possible = 0
        var all: [[Bool?]] = []
        for path in paths {
            var marks: [Bool?] = []
            for h in 0..<path.hops.count {
                guard let from = partner[path.anchors[h]], let to = partner[path.anchors[h + 1]], let start = local[from] else {
                    marks.append(nil)
                    continue
                }
                possible += 1
                let landed = PathWalker.next(from: start, anchors: sharedAnchors, pointerBits: pointerBits).map { shared[$0] }
                let ok = landed == to
                if ok { retraced += 1 }
                marks.append(ok)
            }
            all.append(marks)
        }
        return RetraceResult(retraced: retraced, possible: possible, hops: all)
    }
}
