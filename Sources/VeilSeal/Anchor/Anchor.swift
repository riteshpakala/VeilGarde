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

    public static let sealCount = 1000
    public static let searchCount = 1500

    /// Finds anchors, measures their patterns and, with `residual`, their warp residual.
    public static func read(_ cg: CGImage, key: SealKey, measure: any NeighbourhoodMeasure, count: Int, residual: Bool) throws -> AnchorReading {
        let image = try SealImage(cg)
        let space = ScaleSpace(image)
        let found = AnchorFinder.find(space, count: count)
        let squares = CanonicalPatch.cut(found, from: space)
        let codes = measure.codes(squares)
        let warp = residual ? AnchorResidual.read(squares, count: found.count, key: key) : nil
        let k = Float(image.toOriginal)
        let anchors = found.enumerated().map { n, a in
            Anchor(x: a.x * k, y: a.y * k, scale: a.sigma * k, angle: a.angle, response: a.response, code: codes[n],
                   fragility: warp?.fragility[n], residual: warp?.bits[n])
        }
        return AnchorReading(anchors: anchors, width: image.originalWidth, height: image.originalHeight,
                             workingWidth: image.width, workingHeight: image.height, toOriginal: image.toOriginal)
    }
}
