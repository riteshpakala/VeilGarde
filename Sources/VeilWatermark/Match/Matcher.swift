//
//  Matcher.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Whether an image is (a crop of) a signed one, and where it sits: the image's tile codes,
//        read at several sub-tile grid phases, slid over the signature's at every whole-tile
//        offset; the best agreement is the match.
//  PIN:  score = 1 − mismatched / compared bits, over the bits both grids measured; the crop is
//        taken to lie inside the signed image, so offsets run over the containing range with a
//        one-tile margin. zScore = (score − 0.5) / √(0.25 / bits), the agreement's distance from
//        chance in coin-flip units. A match needs score ≥ 0.75 and ≥ 256 compared bits (the v1
//        acceptance bar). Phases default to the 16 of {0, 8, 16, 24}² px, so
//        some phase sits within 4 px of the signed grid on each axis.
//

import Foundation

public struct MatchOptions: Sendable, Equatable {
    public var phases: [Int]
    public var minimumBits: Int
    public var threshold: Double
    public var margin: Int

    public init(phases: [Int] = [0, 8, 16, 24], minimumBits: Int = 256, threshold: Double = 0.75, margin: Int = 1) {
        self.phases = phases
        self.minimumBits = minimumBits
        self.threshold = threshold
        self.margin = margin
    }

    public static let `default` = MatchOptions()
}

public struct MatchResult: Codable, Sendable, Equatable {
    /// Where the image's phase grid sits on the signed grid, in tiles.
    public var offsetX: Int
    public var offsetY: Int
    /// The image's grid phase that matched, in pixels.
    public var phaseX: Int
    public var phaseY: Int
    public var score: Double
    public var bitsCompared: Int
    public var zScore: Double
    public var matched: Bool

    /// The signed-image pixel the image's top-left corresponds to (offset · 32 − phase).
    public var pixelX: Int { offsetX * WarpConstants.tileSize - phaseX }
    public var pixelY: Int { offsetY * WarpConstants.tileSize - phaseY }

    public static let none = MatchResult(offsetX: 0, offsetY: 0, phaseX: 0, phaseY: 0, score: 0, bitsCompared: 0, zScore: 0, matched: false)
}

public enum Matcher {
    /// The best whole-tile offset of `crop` on `stored`: (dx, dy, mismatches, compared bits), or nil.
    public static func best(crop: TileCodeGrid, stored: TileCodeGrid, margin: Int = 1, minimumBits: Int) -> (dx: Int, dy: Int, score: Double, bits: Int)? {
        var best: (Int, Int, Double, Int)? = nil
        let CR = crop.rows, CC = crop.cols, SR = stored.rows, SC = stored.cols
        guard CR > 0, CC > 0, SR > 0, SC > 0 else { return nil }
        crop.bits.withUnsafeBufferPointer { cb in
            crop.masks.withUnsafeBufferPointer { cm in
                stored.bits.withUnsafeBufferPointer { sb in
                    stored.masks.withUnsafeBufferPointer { sm in
                        let lowY = min(-margin, SR - CR + margin), highY = max(SR - CR + margin, -margin)
                        let lowX = min(-margin, SC - CC + margin), highX = max(SC - CC + margin, -margin)
                        for dy in lowY...highY {
                            for dx in lowX...highX {
                                var bits = 0, bad = 0
                                let i0 = max(0, -dy), i1 = min(CR, SR - dy)
                                let j0 = max(0, -dx), j1 = min(CC, SC - dx)
                                guard i0 < i1, j0 < j1 else { continue }
                                for i in i0..<i1 {
                                    let crow = i * CC, srow = (i + dy) * SC + dx
                                    for j in j0..<j1 {
                                        let m = cm[crow + j] & sm[srow + j]
                                        bits += m.nonzeroBitCount
                                        bad += ((cb[crow + j] ^ sb[srow + j]) & m).nonzeroBitCount
                                    }
                                }
                                guard bits >= minimumBits else { continue }
                                let score = 1 - Double(bad) / Double(bits)
                                if best == nil || score > best!.2 || (score == best!.2 && bits > best!.3) { best = (dx, dy, score, bits) }
                            }
                        }
                    }
                }
            }
        }
        return best.map { (dx: $0.0, dy: $0.1, score: $0.2, bits: $0.3) }
    }

    public static func zScore(score: Double, bits: Int) -> Double {
        bits > 0 ? (score - 0.5) / (0.25 / Double(bits)).squareRoot() : 0
    }
}
