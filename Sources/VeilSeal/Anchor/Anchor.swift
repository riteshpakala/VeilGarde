//
//  Anchor.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: An anchor as a seal keeps it, and the reading of a whole picture: where each anchor sits in
//        the original's pixels, how large and which way its neighbourhood is, its pattern (code), and
//        its warp residual (FR and 24 bits) when the residual was read.
//  PIN:  Positions and scales are the working picture's times SealImage.toOriginal. `count` anchors at
//        most (1000 for a seal, 1500 for a picture being searched). The residual needs MLX; a reading
//        without it leaves fragility and residual nil.
//

import CoreGraphics
import Foundation

public struct Anchor: Codable, Sendable, Equatable {
    public var x: Float
    public var y: Float
    /// σ, in the original's pixels.
    public var scale: Float
    /// Radians, atan2(dy, dx) with y down.
    public var angle: Float
    public var response: Float
    public var code: Code256
    public var fragility: Float?
    public var residual: UInt32?
}

/// Every anchor of one picture.
public struct AnchorReading: Sendable {
    public var anchors: [Anchor]
    public var width: Int
    public var height: Int
    /// The working picture's size, and its scale to the original.
    public var workingWidth: Int
    public var workingHeight: Int
    public var toOriginal: Double
    /// With the residual read: each anchor's 4×4 cell energies, 16 per anchor (not kept in a seal).
    public var residualCells: [Float]? = nil

    public static let sealCount = 1000
    public static let searchCount = 1500

    /// Finds anchors, measures their patterns and, with `residual`, their warp residual.
    public static func read(_ cg: CGImage, key: SealKey, measure: any NeighbourhoodMeasure, count: Int, residual: Bool) throws -> AnchorReading {
        try read(cg, key: key, measures: [measure], count: count, residual: residual)[0]
    }

    /// One reading per measure, in order: the anchors, their squares and their residual found once, each measure's codes on them.
    /// `selection` other than strength reads the warp residual of twice `count` candidates and keeps `count` of them by it.
    public static func read(_ cg: CGImage, key: SealKey, measures: [any NeighbourhoodMeasure], count: Int, residual: Bool,
                            selection: AnchorSelection = .strength) throws -> [AnchorReading] {
        let image = try SealImage(cg)
        let space = ScaleSpace(image)
        var found = AnchorFinder.find(space, count: selection == .strength ? count : 2 * count)
        var squares = CanonicalPatch.cut(found, from: space)
        var warp = residual || selection != .strength ? AnchorResidual.read(squares, count: found.count, key: key) : nil
        if selection != .strength, let w = warp, found.count > count {
            let ranked = selection.rank(found, fragility: w.fragility)
            let kept = AnchorFinder.spread(ranked.map { found[$0] }, count: count, width: image.width, height: image.height).map { ranked[$0] }
            let side = CanonicalPatch.side * CanonicalPatch.side * 3
            found = kept.map { found[$0] }
            squares = kept.flatMap { squares[($0 * side)..<(($0 + 1) * side)] }
            warp = AnchorResidualRead(fragility: kept.map { w.fragility[$0] }, bits: kept.map { w.bits[$0] },
                                      cells: kept.flatMap { w.cells[($0 * 16)..<(($0 + 1) * 16)] })
        }
        let k = Float(image.toOriginal)
        return measures.map { measure in
            let codes = measure.codes(squares)
            let anchors = found.enumerated().map { n, a in
                Anchor(x: a.x * k, y: a.y * k, scale: a.sigma * k, angle: a.angle, response: a.response, code: codes[n],
                       fragility: warp?.fragility[n], residual: warp?.bits[n])
            }
            return AnchorReading(anchors: anchors, width: image.originalWidth, height: image.originalHeight,
                                 workingWidth: image.width, workingHeight: image.height, toOriginal: image.toOriginal,
                                 residualCells: warp?.cells)
        }
    }
}

/// How a reading keeps its anchors among the candidates: by strength alone, by strength with the warp's fragility
/// breaking near-ties (responses within 10% of each other), or by fragility among the strongest twice as many.
public enum AnchorSelection: String, Codable, Sendable, CaseIterable {
    case strength, tieBreak, fragile

    /// Candidate indices, best first.
    func rank(_ found: [FoundAnchor], fragility: [Float]) -> [Int] {
        let band: (Int) -> Int = { Int(floor(log(max(1e-9, found[$0].response)) / log(1.1))) }
        switch self {
        case .strength:
            return Array(found.indices)
        case .tieBreak:
            return found.indices.sorted {
                let a = band($0), b = band($1)
                if a != b { return a > b }
                return fragility[$0] != fragility[$1] ? fragility[$0] > fragility[$1] : $0 < $1
            }
        case .fragile:
            return found.indices.sorted { fragility[$0] != fragility[$1] ? fragility[$0] > fragility[$1] : $0 < $1 }
        }
    }
}
