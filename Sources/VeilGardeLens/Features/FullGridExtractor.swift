//
//  FullGridExtractor.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Every 32×32 tile of the padded image measured with the TRAINING feature semantics: the
//        warp residual and tile-local features in chunks (pass A, bounded GPU memory), then the
//        cross-tile features over the whole grid in one graph (pass B): CC/CR against the
//        point-mirrored tile, seams against true grid neighbours (zeros only at the last row and
//        column), the demosaic and spectral columns, and the directional signature when asked.
//        Then, separately, the tile probabilities block-averaged into the patch grid and the
//        patches' texture weights.
//  PIN:  Garde's scoreImageFullGrid, split so training can take the rows without a scorer and the
//        op sequence and eval grouping stay Garde's (pass A evaluates each ≤256-tile chunk; pass B
//        evaluates the stacked [N, 19 (+21)] block once). The directional signature runs on the
//        UNPADDED plane when it covers the scored grid (training semantics), else on the padded
//        one. Rows are tile-grid row-major.
//

import Foundation
import MLX
import MLXAccelerate

/// Every tile's feature row, in grid order.
public struct TileFeatureMap: Sendable {
    public let tileRows: Int
    public let tileCols: Int
    public let featureCount: Int
    /// [tileRows · tileCols · featureCount], row-major.
    public let values: [Float]

    public var count: Int { tileRows * tileCols }

    public func row(_ t: Int) -> ArraySlice<Float> { values[(t * featureCount)..<((t + 1) * featureCount)] }

    public var rowsArray: [[Float]] { (0..<count).map { Array(row($0)) } }

    /// Garde's `--dump-features` JSON, byte for byte: the patch grid, the tiles per patch, the
    /// order, the column names sliced to the row width, and the rows.
    public func dumpJSON(patchRows: Int, patchCols: Int, tilesPerPatch: Int) throws -> Data {
        let names = (WarpFeatures.names + DirectionalSignature.names).prefix(featureCount)
        let object: [String: Any] = [
            "grid": ["rows": patchRows, "cols": patchCols, "tiles_per_patch": tilesPerPatch],
            "order": "grid",
            "feature_order": Array(names),
            "features": rowsArray.map { $0.map { Double($0) } },
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

public enum FullGridExtractor {
    /// The tile feature rows of a padded image `img` [padH, padW, 3] (0–255).
    public static func features(img: MLXArray, padH: Int, padW: Int, tables: WarpTables, signature: Bool,
                                sigPlane: MLXArray? = nil, sigH: Int = 0, sigW: Int = 0,
                                progress: (Int, Int) -> Void = { _, _ in }) -> TileFeatureMap {
        let ts = WarpConstants.tileSize, strip = WarpConstants.stripWidth
        let TR = padH / ts, TC = padW / ts
        let Ntot = TR * TC
        let tiles = img.reshaped([TR, ts, TC, ts, 3]).transposed(0, 2, 1, 3, 4).reshaped([Ntot, ts * ts, 3])

        // Pass A: chunked warp residuals and tile-local features.
        var RlChunks = [MLXArray](), FRs = [MLXArray](), LVs = [MLXArray](), CVs = [MLXArray](), CMs = [MLXArray]()
        var a = 0
        while a < Ntot {
            let b = min(a + WarpConstants.evalTileBudget, Ntot)
            let chunk = tiles[a..<b]
            let Rl = WarpResidual.batch(chunk, forward: tables.lowForward, back: tables.lowBack)
            let Rh = WarpResidual.batch(chunk, forward: tables.highForward, back: tables.highBack)
            let FR = WarpResidual.fragility(low: Rl, high: Rh)
            let lm = batchedFilter2D(Rl, kernel: tables.localVarianceKernel)
            let lm2 = batchedFilter2D(Rl * Rl, kernel: tables.localVarianceKernel)
            let LV = MLX.maximum(lm2 - lm * lm, MLXArray(Float(0))).mean(axes: [1, 2])
            let (gx, gy) = batchedSobelGradients(Rl)
            let ang = MLX.atan2(gy, gx)
            let Rf = MLX.sqrt(batchedFilter2D(MLX.cos(ang), kernel: tables.circularVarianceKernel).pow(2)
                              + batchedFilter2D(MLX.sin(ang), kernel: tables.circularVarianceKernel).pow(2))
            let cvMap = MLXArray(Float(1.0)) - Rf
            let CV = cvMap.mean(axes: [1, 2])
            // Python: (|R_l| * (1 - cv_map)).mean(): keep the double rounding, not just Rf.
            let CM = (MLX.abs(Rl) * (MLXArray(Float(1.0)) - cvMap)).mean(axes: [1, 2])
            MLX.eval(Rl, FR, LV, CV, CM)
            RlChunks.append(Rl); FRs.append(FR); LVs.append(LV); CVs.append(CV); CMs.append(CM)
            progress(b, Ntot)
            a = b
        }

        // Pass B: cross-tile features over the whole grid, one graph.
        let RlAll = RlChunks.count == 1 ? RlChunks[0] : MLX.concatenated(RlChunks, axis: 0)
        let maps = RlAll.reshaped([Ntot, ts * ts])
        var mirror = [Int32](repeating: 0, count: Ntot)
        for i in 0..<TR { for j in 0..<TC { mirror[i * TC + j] = Int32((TR - 1 - i) * TC + (TC - 1 - j)) } }
        let opp = maps.take(MLXArray(mirror), axis: 0)
        let acm = maps - maps.mean(axes: [1], keepDims: true)
        let bcm = opp - opp.mean(axes: [1], keepDims: true)
        let num = (acm * bcm).mean(axes: [1])
        let den = MLX.sqrt((acm * acm).mean(axes: [1]) * (bcm * bcm).mean(axes: [1]) + Float(1e-12))
        let CC = num / den
        let s1 = MLX.sqrt(maps.variance(axes: [1]))
        let s2 = MLX.sqrt(opp.variance(axes: [1]))
        let CR = MLX.minimum(s1, s2) / MLX.maximum(MLX.maximum(s1, s2), MLXArray(Float(1e-12)))

        let topS = RlAll[0..., 0..<strip, 0...].mean(axes: [1])
        let botS = RlAll[0..., (ts - strip)..., 0...].mean(axes: [1])
        let lftS = RlAll[0..., 0..., 0..<strip].mean(axes: [2])
        let rgtS = RlAll[0..., 0..., (ts - strip)...].mean(axes: [2])
        let (SH, SHS) = SeamFeatures.compute(botS, topS, G: 1, nr: TR, nc: TC, axis: 1)
        let (SV, SVS) = SeamFeatures.compute(rgtS, lftS, G: 1, nr: TR, nc: TC, axis: 2)

        // Demosaic features from the raw channels: the high-pass runs on the whole padded plane.
        let Rch = img[.ellipsis, 0..<1].squeezed(axis: -1).reshaped([1, padH, padW])
        let Gch = img[.ellipsis, 1..<2].squeezed(axis: -1).reshaped([1, padH, padW])
        let Bch = img[.ellipsis, 2..<3].squeezed(axis: -1).reshaped([1, padH, padW])
        let rhT = DemosaicFeatures.tileHF(DemosaicFeatures.hf3(Rch), TR: TR, TC: TC)
        let ghT = DemosaicFeatures.tileHF(DemosaicFeatures.hf3(Gch), TR: TR, TC: TC)
        let bhT = DemosaicFeatures.tileHF(DemosaicFeatures.hf3(Bch), TR: TR, TC: TC)
        let XR = DemosaicFeatures.tileXcorr(rhT, ghT), CFA = DemosaicFeatures.tileCfa(ghT)
        let ex = DemosaicFeatures.extras(rhT, ghT, bhT, Gpl: Gch, padH: padH, padW: padW, TR: TR, TC: TC)

        let sig: [MLXArray]
        if signature, let sp = sigPlane, ScoringGeometry.unpaddedPlaneCoversSignatureGrid(sigH: sigH, sigW: sigW, TR: TR, TC: TC) {
            sig = DirectionalProbes.compute(img: sp, H: sigH, W: sigW, TR: TR, TC: TC, quantizeLikeCV2: tables.quantizeLikeCV2)
        } else if signature {
            sig = DirectionalProbes.compute(img: img, H: padH, W: padW, TR: TR, TC: TC, quantizeLikeCV2: tables.quantizeLikeCV2)
        } else {
            sig = []
        }

        let featAll = MLX.stacked(
            [MLX.concatenated(FRs, axis: 0), MLX.concatenated(LVs, axis: 0), MLX.concatenated(CVs, axis: 0), MLX.concatenated(CMs, axis: 0),
             CC, CR, SH.reshaped([Ntot]), SV.reshaped([Ntot]), SHS.reshaped([Ntot]), SVS.reshaped([Ntot]),
             XR, CFA, ex.xBG, ex.xRB, ex.cfaR, ex.cfaB, ex.noiseRatio, ex.diagAxial, ex.nyqR] + sig,
            axis: 1)
        MLX.eval(featAll)
        return TileFeatureMap(tileRows: TR, tileCols: TC, featureCount: WarpFeatures.count + sig.count, values: featAll.asArray(Float.self))
    }

    /// Tile probabilities block-averaged into the patch grid (patchSize a multiple of 32).
    public static func patchGrid(tileProbabilities: [Float], tileCols: Int, padH: Int, padW: Int, patchSize ps: Int) -> [[Float]] {
        let n = ps / WarpConstants.tileSize
        let Pr = padH / ps, Pc = padW / ps
        var grid = [[Float]](repeating: [Float](repeating: 0, count: Pc), count: Pr)
        for I in 0..<Pr {
            for J in 0..<Pc {
                var s: Float = 0
                for ti in 0..<n { for tj in 0..<n { s += tileProbabilities[(I * n + ti) * tileCols + (J * n + tj)] } }
                grid[I][J] = s / Float(n * n)
            }
        }
        return grid
    }

    /// Each patch's texture weight: the mean Sobel magnitude over cv2's uint8 gray.
    public static func textureWeights(img: MLXArray, padH: Int, padW: Int, patchSize ps: Int) -> [[Float]] {
        let Pr = padH / ps, Pc = padW / ps
        let allPatches = img.reshaped([Pr, ps, Pc, ps, 3]).transposed(0, 2, 1, 3, 4).reshaped([Pr * Pc, ps, ps, 3])
        let gray = Gray.cv2U8(allPatches)
        let (tgx, tgy) = batchedSobelGradients(gray)
        let tex = MLX.sqrt(tgx * tgx + tgy * tgy).mean(axes: [1, 2])
        MLX.eval(tex)
        let flat = tex.asArray(Float.self)
        var weights = [[Float]](repeating: [Float](repeating: 0, count: Pc), count: Pr)
        for I in 0..<Pr { for J in 0..<Pc { weights[I][J] = flat[I * Pc + J] } }
        return weights
    }
}
