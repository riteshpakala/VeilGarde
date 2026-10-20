//
//  WarpLens.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The warp lens end to end on one image: load and pad, choose the scoring canvas, measure
//        every tile, score the tiles, block them into the patch grid, weigh the patches, and
//        produce the weighted score and the sharpness the fusion reads. Training calls
//        `tileFeatures` for the rows alone; the watermark calls `fragility` for the per-tile FR.
//  PIN:  The base pass of Garde's runInferenceFast, unchanged in order and arithmetic. A model
//        with more than 19 columns scores the truncated grid and computes its signature on the
//        unpadded plane (the v2.6 geometry law); the shipped 19-column model keeps the padded
//        grid. The warp tap tables are constants, built once per quantization mode.
//

import CoreGraphics
import Foundation
import MLX

public struct WarpParameters: Sendable, Equatable {
    public var patchSize: Int
    public var maxDim: Int
    public var fullResolution: Bool
    public var quantizeLikeCV2: Bool
    public var weightMap: WeightMapParameters
    public var hotspot: HotspotRule
    public var nativeCheck: Bool
    public var keepFeatures: Bool

    public init(patchSize: Int = 32, maxDim: Int = 512, fullResolution: Bool = false, quantizeLikeCV2: Bool = true,
                weightMap: WeightMapParameters = WeightMapParameters(), hotspot: HotspotRule = HotspotRule(),
                nativeCheck: Bool = false, keepFeatures: Bool = false) {
        self.patchSize = patchSize
        self.maxDim = maxDim
        self.fullResolution = fullResolution
        self.quantizeLikeCV2 = quantizeLikeCV2
        self.weightMap = weightMap
        self.hotspot = hotspot
        self.nativeCheck = nativeCheck
        self.keepFeatures = keepFeatures
    }

    /// The longest-edge cap actually applied (0 under fullResolution).
    public var effectiveMaxDim: Int { fullResolution ? 0 : maxDim }
}

/// What the warp lens measured on one image.
public struct WarpAnalysis {
    public let geometry: ScoringGeometry
    public let patchSize: Int
    /// The scored canvas (padded for 19 columns, truncated for a directional model).
    public let scoredWidth: Int
    public let scoredHeight: Int
    public let patchGrid: [[Float]]
    public let texWeights: [[Float]]
    public let weightMap: [[Float]]
    public let weightedScore: Float
    public let sharpness: SharpnessFeatures
    public let tileProbabilities: [Float]
    public let tileCols: Int
    /// The tile feature rows, kept when asked (`keepFeatures`).
    public let features: TileFeatureMap?
    public let nativeScore: Float?
    public let nativeDisagreement: Float?

    public var patchRows: Int { patchGrid.count }
    public var patchCols: Int { patchGrid.first?.count ?? 0 }
}

public enum WarpLens {
    public static func analyze(cgImage: CGImage, parameters: WarpParameters, scorer: TileScorer,
                               progress: (Int, Int) -> Void = { _, _ in }) throws -> WarpAnalysis {
        let loaded = try ImageLoading.load(cgImage, maxDim: parameters.effectiveMaxDim, patchSize: parameters.patchSize)
        let geometry = ScoringGeometry.make(realWidth: loaded.realWidth, realHeight: loaded.realHeight,
                                            paddedWidth: loaded.paddedWidth, paddedHeight: loaded.paddedHeight, featureCount: scorer.featureCount)
        var img = loaded.array, padW = loaded.paddedWidth, padH = loaded.paddedHeight
        var sigPlane: MLXArray? = nil
        var sigH = 0, sigW = 0
        if scorer.featureCount > WarpFeatures.count {
            sigPlane = img[0..<loaded.realHeight, 0..<loaded.realWidth, 0...]
            sigH = loaded.realHeight; sigW = loaded.realWidth
            if geometry.scoringWidth != padW || geometry.scoringHeight != padH {
                img = img[0..<geometry.scoringHeight, 0..<geometry.scoringWidth, 0...]
                padW = geometry.scoringWidth; padH = geometry.scoringHeight
            }
        }
        let ps = parameters.patchSize
        let tables = WarpTables.shared(quantizeLikeCV2: parameters.quantizeLikeCV2)
        let scored = score(img: img, padH: padH, padW: padW, patchSize: ps, tables: tables, scorer: scorer,
                           sigPlane: sigPlane, sigH: sigH, sigW: sigW, progress: progress)
        let weightMap = WeightMap.build(patchGrid: scored.patchGrid, texWeights: scored.texWeights, parameters: parameters.weightMap)
        let weighted = WeightedVerdict.score(patchGrid: scored.patchGrid, weightMap: weightMap, hotspot: parameters.hotspot)
        let sharpness = SharpnessFeatures.measure(texWeights: scored.texWeights, weightMap: weightMap)

        var nativeScore: Float? = nil, nativeDisagreement: Float? = nil
        if parameters.nativeCheck, let crop = ImageLoading.centerCrop(cgImage, maxDim: parameters.effectiveMaxDim, patchSize: ps) {
            let n = score(img: crop.array, padH: crop.side, padW: crop.side, patchSize: ps, tables: tables, scorer: scorer)
            let nMap = WeightMap.build(patchGrid: n.patchGrid, texWeights: n.texWeights, parameters: parameters.weightMap)
            let ns = WeightedVerdict.score(patchGrid: n.patchGrid, weightMap: nMap, hotspot: parameters.hotspot)
            nativeScore = ns
            nativeDisagreement = abs(weighted - ns)
        }
        return WarpAnalysis(geometry: geometry, patchSize: ps, scoredWidth: padW, scoredHeight: padH, patchGrid: scored.patchGrid,
                            texWeights: scored.texWeights, weightMap: weightMap, weightedScore: weighted, sharpness: sharpness,
                            tileProbabilities: scored.tileProbabilities, tileCols: scored.features.tileCols,
                            features: parameters.keepFeatures ? scored.features : nil, nativeScore: nativeScore, nativeDisagreement: nativeDisagreement)
    }

    /// Features, scores, the patch grid and its texture weights for one scored canvas.
    public static func score(img: MLXArray, padH: Int, padW: Int, patchSize ps: Int, tables: WarpTables, scorer: TileScorer,
                      sigPlane: MLXArray? = nil, sigH: Int = 0, sigW: Int = 0, progress: (Int, Int) -> Void = { _, _ in })
        -> (patchGrid: [[Float]], texWeights: [[Float]], tileProbabilities: [Float], features: TileFeatureMap) {
        let features = FullGridExtractor.features(img: img, padH: padH, padW: padW, tables: tables, signature: scorer.featureCount > WarpFeatures.count,
                                                  sigPlane: sigPlane, sigH: sigH, sigW: sigW, progress: progress)
        let probabilities = scorer.scoreBatch(features.rowsArray)
        let grid = FullGridExtractor.patchGrid(tileProbabilities: probabilities, tileCols: features.tileCols, padH: padH, padW: padW, patchSize: ps)
        let tex = FullGridExtractor.textureWeights(img: img, padH: padH, padW: padW, patchSize: ps)
        return (grid, tex, probabilities, features)
    }

    /// The 32-px sensor lane of an image under its own scorer: the dual-warp law's dedicated pass,
    /// whatever the base pass's presentation patch size. Returns the tile grid and the geometry.
    public static func sensorLane(cgImage: CGImage, parameters: WarpParameters, scorer: TileScorer) throws -> (grid: [[Float]], rows: Int, cols: Int, geometry: ScoringGeometry) {
        let ps = WarpConstants.tileSize
        let loaded = try ImageLoading.load(cgImage, maxDim: parameters.effectiveMaxDim, patchSize: ps)
        let geometry = ScoringGeometry.make(realWidth: loaded.realWidth, realHeight: loaded.realHeight,
                                            paddedWidth: loaded.paddedWidth, paddedHeight: loaded.paddedHeight, featureCount: scorer.featureCount)
        var img = loaded.array, padW = loaded.paddedWidth, padH = loaded.paddedHeight
        var sigPlane: MLXArray? = nil
        var sigH = 0, sigW = 0
        if scorer.featureCount > WarpFeatures.count {
            sigPlane = img[0..<loaded.realHeight, 0..<loaded.realWidth, 0...]
            sigH = loaded.realHeight; sigW = loaded.realWidth
            if geometry.scoringWidth != padW || geometry.scoringHeight != padH {
                img = img[0..<geometry.scoringHeight, 0..<geometry.scoringWidth, 0...]
                padW = geometry.scoringWidth; padH = geometry.scoringHeight
            }
        }
        let scored = score(img: img, padH: padH, padW: padW, patchSize: ps, tables: WarpTables.shared(quantizeLikeCV2: parameters.quantizeLikeCV2),
                           scorer: scorer, sigPlane: sigPlane, sigH: sigH, sigW: sigW)
        return (scored.patchGrid, padH / ps, padW / ps, geometry)
    }

    /// The 19 tile features of an image on the shipped geometry (512 cap, reflect-padded 32-px
    /// grid), without a scorer: what the warp tile model trains on.
    public static func tileFeatures(cgImage: CGImage, maxDim: Int = 512, quantizeLikeCV2: Bool = true) throws -> (map: TileFeatureMap, geometry: ScoringGeometry) {
        let t = try trainingTiles(cgImage: cgImage, maxDim: maxDim, quantizeLikeCV2: quantizeLikeCV2)
        return (t.map, t.geometry)
    }

    /// The tile features with each tile's texture weight (row-major over the same grid): with
    /// them a trained model's tile probabilities become the image's weighted score exactly as
    /// `analyze` makes it, without the image.
    public static func trainingTiles(cgImage: CGImage, maxDim: Int = 512, quantizeLikeCV2: Bool = true) throws
        -> (map: TileFeatureMap, texture: [Float], geometry: ScoringGeometry) {
        trainingTiles(prepared: try ImageLoading.prepare(cgImage, maxDim: maxDim, patchSize: WarpConstants.tileSize), quantizeLikeCV2: quantizeLikeCV2)
    }

    /// The same from an image already prepared on the CPU (ImageLoading.prepare at 32 px).
    public static func trainingTiles(prepared: PreparedImage, quantizeLikeCV2: Bool = true) -> (map: TileFeatureMap, texture: [Float], geometry: ScoringGeometry) {
        let loaded = ImageLoading.load(prepared)
        let tables = WarpTables.shared(quantizeLikeCV2: quantizeLikeCV2)
        let map = FullGridExtractor.features(img: loaded.array, padH: loaded.paddedHeight, padW: loaded.paddedWidth, tables: tables, signature: false)
        let texture = FullGridExtractor.textureWeights(img: loaded.array, padH: loaded.paddedHeight, padW: loaded.paddedWidth,
                                                       patchSize: WarpConstants.tileSize).flatMap { $0 }
        let geometry = ScoringGeometry(imageWidth: loaded.realWidth, imageHeight: loaded.realHeight,
                                       scoringWidth: loaded.paddedWidth, scoringHeight: loaded.paddedHeight)
        return (map, texture, geometry)
    }
}
