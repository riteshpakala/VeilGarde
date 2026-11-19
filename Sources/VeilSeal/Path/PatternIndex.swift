//
//  PatternIndex.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Which anchor of a found picture may be which anchor of a seal: for each of the picture's
//        patterns, the seal's nearest by Hamming distance, kept only when clearly nearer than the next
//        (ratio test) and close enough; each seal anchor keeps its best claimant.
//  PIN:  Brute force over the seal's codes (popcount of four words). Kept when best ≤ 64 of 256 bits and
//        best < 0.8 × second best. One-to-one by the smaller distance, ties to the earlier query anchor.
//  ROBUSTNESS: Class I · Compression; Class II · Filters — a pattern a few bits off still finds its
//        anchor; the ratio test drops patterns too common in the seal to say anything.
//

import Foundation

struct Correspondence: Sendable, Equatable {
    var seal: Int
    var query: Int
    var distance: Int
}

enum PatternIndex {
    static let maxDistance = 64
    static let ratio: Float = 0.8

    static func match(query: [Anchor], seal: [Anchor]) -> [Correspondence] {
        guard !seal.isEmpty else { return [] }
        let sealCodes = seal.map(\.code)
        var bestFor = [Int: Correspondence]()
        sealCodes.withUnsafeBufferPointer { codes in
            for (qi, q) in query.enumerated() {
                var best = Int.max, second = Int.max, bestIndex = -1
                for si in 0..<codes.count {
                    let d = q.code.distance(codes[si])
                    if d < best {
                        second = best
                        best = d
                        bestIndex = si
                    } else if d < second {
                        second = d
                    }
                }
                guard bestIndex >= 0, best <= maxDistance, Float(best) < ratio * Float(second) else { continue }
                if let held = bestFor[bestIndex], held.distance <= best { continue }
                bestFor[bestIndex] = Correspondence(seal: bestIndex, query: qi, distance: best)
            }
        }
        return bestFor.values.sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.query < $1.query }
    }
}
