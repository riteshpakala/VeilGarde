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
//  PIN:  Paths start at the 96 strongest anchors (distinct places); a path ends early at a sector with
//        no anchor in reach or at an anchor already on it. Sector k covers [k·45°, (k + 1)·45°) from the
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
    static let starts = 96
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

    /// The seal's paths.
    static func walk(_ anchors: [Anchor], pointerBits: [Int]) -> [SealPath] {
        let order = anchors.indices.sorted {
            anchors[$0].response != anchors[$1].response ? anchors[$0].response > anchors[$1].response : $0 < $1
        }
        var seenPlaces = Set<Int64>()
        var paths: [SealPath] = []
        for start in order where paths.count < starts {
            let a = anchors[start]
            let place = Int64(a.x.rounded()) << 32 | Int64(a.y.rounded())
            guard seenPlaces.insert(place).inserted else { continue }
            var chain = [start]
            var hops: [SealPath.Hop] = []
            var current = start
            while hops.count < Self.hops, let n = next(from: current, anchors: anchors, pointerBits: pointerBits), !chain.contains(n) {
                hops.append(hop(anchors[current], anchors[n]))
                chain.append(n)
                current = n
            }
            if !hops.isEmpty { paths.append(SealPath(anchors: chain, hops: hops)) }
        }
        return paths
    }
}
