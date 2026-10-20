//
//  ScoringGeometry.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Where the tiles fall. The lens scores a reflect-padded canvas (the image after the 512
//        cap, padded right and bottom to a multiple of 32), reports in the real image's
//        coordinates, and maps each sensor cell onto the frozen base grid's weight.
//  PIN:  Garde's scoring geometry and its helpers, unchanged. A 19-column model scores the
//        padded canvas; a directional (more than 19 columns) model drops incomplete edge tiles to
//        keep its training geometry, unless that leaves fewer than four tiles a side. Base weights
//        are never renormalized when a sensor grid exposes only part of the base map
//        (InferenceResult.visibleBaseWeightShare may sum below 1).
//

public struct ScoringGeometry: Equatable, Sendable {
    /// The warp lens's tile side, in pixels.
    public static let tileSize = 32

    public let imageWidth: Int
    public let imageHeight: Int
    public let scoringWidth: Int
    public let scoringHeight: Int

    public init(imageWidth: Int, imageHeight: Int, scoringWidth: Int, scoringHeight: Int) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.scoringWidth = scoringWidth
        self.scoringHeight = scoringHeight
    }

    /// The canvas a model with `featureCount` columns scores.
    public static func make(realWidth: Int, realHeight: Int, paddedWidth: Int, paddedHeight: Int, featureCount: Int) -> ScoringGeometry {
        var scoringWidth = paddedWidth
        var scoringHeight = paddedHeight
        if featureCount > WarpFeatures.count {
            let truncatedWidth = (realWidth / tileSize) * tileSize
            let truncatedHeight = (realHeight / tileSize) * tileSize
            if truncatedWidth >= 4 * tileSize, truncatedHeight >= 4 * tileSize,
               truncatedWidth != paddedWidth || truncatedHeight != paddedHeight {
                scoringWidth = truncatedWidth
                scoringHeight = truncatedHeight
            }
        }
        return ScoringGeometry(imageWidth: realWidth, imageHeight: realHeight, scoringWidth: scoringWidth, scoringHeight: scoringHeight)
    }

    /// Whether an already-scored base grid IS the lane the sensor calibration was fitted on: the
    /// raw 32-px tile grid. At a presentation patch size of 64/128/256 each base cell is the mean
    /// of a tile block, a different statistic, so the sensor is rescored on its own lane.
    public static func baseGridIsSensorLane(patchSize: Int) -> Bool { patchSize == tileSize }

    /// Whether the unpadded plane can serve the directional signature for a TR × TC scored grid:
    /// the signature reads exactly TR·32 × TC·32 pixels, so the real plane is usable only when the
    /// scored grid is the truncated one (Garde's reshape-crash regression, 512×120 vs 512×128).
    public static func unpaddedPlaneCoversSignatureGrid(sigH: Int, sigW: Int, TR: Int, TC: Int) -> Bool {
        sigH > 0 && sigW > 0 && sigH >= TR * tileSize && sigW >= TC * tileSize
    }

    /// The frozen base weight one selected-sensor cell at (x, y) represents. Callers never
    /// renormalize these when edge cells are absent.
    public static func baseWeightContribution(weightMap: [[Float]], x: Int, y: Int, basePatchSize: Int, sensorPatchSize: Int) -> Float {
        guard x >= 0, y >= 0, basePatchSize > 0, sensorPatchSize > 0 else { return 0 }
        let baseI = y / basePatchSize
        let baseJ = x / basePatchSize
        let cellsPerBasePatch = max(1, (basePatchSize / sensorPatchSize) * (basePatchSize / sensorPatchSize))
        guard baseI < weightMap.count, baseJ < weightMap[baseI].count else { return 0 }
        return weightMap[baseI][baseJ] / Float(cellsPerBasePatch)
    }
}
