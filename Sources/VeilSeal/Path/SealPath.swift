//
//  SealPath.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Step 2, paths →: the pattern picks the next anchor. From an anchor, three of its pattern's
//        pointer bits name one of eight sectors around it (turned with its orientation); the path steps
//        to the nearest anchor in that sector between 2σ and 40σ away, and walks on for six hops. A path
//        keeps its anchors and each hop's shape in the anchor's own units (angle from its orientation,
//        log of distance over σ, log of the scale ratio), so the same walk reads the same in a resized
//        or turned copy. The seal's signature string is its paths' patterns, one after another.
//  PIN:  Paths start at 128 anchors spread over the picture: the anchors' bounding box cut into 8 × 8
//        cells, the strongest of every cell taken first (strongest cell first), then the second of
//        every cell, and so on, at distinct places. A crop then holds paths wherever it falls (the
//        96 strongest anywhere clustered, and some crops held none: tuning, 2026-11-18). A path ends
//        early at a sector with no anchor in reach or at an anchor already on it. Sector k covers [k·45°, (k + 1)·45°) from the
//        orientation; nearest is by distance. Pointer bits are the measure's first three.
//  ROBUSTNESS: false-match control — a stranger's anchors may share patterns by chance, but not the
//        walk from one to the next; a crop keeps the hops inside it (Step 5 checks hops one at a time).
//

import Foundation

public struct SealPath: Codable, Sendable, Equatable {
    public struct Hop: Codable, Sendable, Equatable {
        /// Radians from the anchor's orientation to the next anchor.
        public var angle: Float
        /// log(distance / σ).
        public var reach: Float
        /// log(σ next / σ).
        public var scale: Float
    }

    /// Indices into the seal's anchors, in walking order.
    public var anchors: [Int]
    public var hops: [Hop]
}

enum PathWalker {
    static let starts = 128
    static let cells = 8
    static let hops = 6
    static let sectors = 8
    static let nearest: Float = 2
    static let farthest: Float = 40

    /// The anchor `from` points at among `anchors`, or nil.
    static func next(from i: Int, anchors: [Anchor], pointerBits: [Int]) -> Int? {
        let a = anchors[i]
        var sector = 0
        for n in 0..<3 where a.code.bit(pointerBits[n]) { sector |= 1 << n }
        var best: Int?
        var bestDistance = Float.greatestFiniteMagnitude
        let low = nearest * a.scale, high = farthest * a.scale
        for (j, b) in anchors.enumerated() where j != i {
            let dx = b.x - a.x, dy = b.y - a.y
            let d = (dx * dx + dy * dy).squareRoot()
            guard d >= low, d <= high, d < bestDistance else { continue }
            guard sectorOf(dx, dy, a.angle) == sector else { continue }
            best = j
            bestDistance = d
        }
        return best
    }

    @inline(__always) static func sectorOf(_ dx: Float, _ dy: Float, _ angle: Float) -> Int {
        var phi = atan2(dy, dx) - angle
        while phi < 0 { phi += 2 * .pi }
        while phi >= 2 * .pi { phi -= 2 * .pi }
        return min(sectors - 1, Int(phi / (2 * .pi / Float(sectors))))
    }

    static func hop(_ a: Anchor, _ b: Anchor) -> SealPath.Hop {
        let dx = b.x - a.x, dy = b.y - a.y
        var phi = atan2(dy, dx) - a.angle
        while phi < 0 { phi += 2 * .pi }
        while phi >= 2 * .pi { phi -= 2 * .pi }
        return SealPath.Hop(angle: phi, reach: log(max(1e-6, (dx * dx + dy * dy).squareRoot() / a.scale)), scale: log(b.scale / a.scale))
    }

    /// Where the paths start: the strongest anchor of each cell first, then the second of each, at distinct places.
    static func startOrder(_ anchors: [Anchor]) -> [Int] {
        guard let x0 = anchors.map(\.x).min(), let x1 = anchors.map(\.x).max(),
              let y0 = anchors.map(\.y).min(), let y1 = anchors.map(\.y).max() else { return [] }
        let w = max(1, x1 - x0) * 1.0001, h = max(1, y1 - y0) * 1.0001
        var byCell = [Int: [Int]]()
        for i in anchors.indices {
            let cx = Int(Float(cells) * (anchors[i].x - x0) / w), cy = Int(Float(cells) * (anchors[i].y - y0) / h)
            byCell[cy * cells + cx, default: []].append(i)
        }
        let stronger: (Int, Int) -> Bool = { anchors[$0].response != anchors[$1].response ? anchors[$0].response > anchors[$1].response : $0 < $1 }
        let ranked = byCell.values.map { $0.sorted(by: stronger) }
        var order: [Int] = []
        var rank = 0
        while order.count < anchors.count {
            let round = ranked.compactMap { rank < $0.count ? $0[rank] : nil }.sorted(by: stronger)
            if round.isEmpty { break }
            order += round
            rank += 1
        }
        return order
    }

    /// The path from `start`: up to six hops, ending early at an empty sector or an anchor already on it.
    static func chain(from start: Int, anchors: [Anchor], pointerBits: [Int]) -> SealPath? {
        var chain = [start]
        var hops: [SealPath.Hop] = []
        var current = start
        while hops.count < Self.hops, let n = next(from: current, anchors: anchors, pointerBits: pointerBits), !chain.contains(n) {
            hops.append(hop(anchors[current], anchors[n]))
            chain.append(n)
            current = n
        }
        return hops.isEmpty ? nil : SealPath(anchors: chain, hops: hops)
    }

    /// The seal's paths.
    static func walk(_ anchors: [Anchor], pointerBits: [Int]) -> [SealPath] {
        var seenPlaces = Set<Int64>()
        var paths: [SealPath] = []
        for start in startOrder(anchors) where paths.count < starts {
            let a = anchors[start]
            let place = Int64(a.x.rounded()) << 32 | Int64(a.y.rounded())
            guard seenPlaces.insert(place).inserted else { continue }
            if let path = chain(from: start, anchors: anchors, pointerBits: pointerBits) { paths.append(path) }
        }
        return paths
    }
}
