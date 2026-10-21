//
//  TileFeatures.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The warp residual's 19 tile features, warp19, over an image capped at 512 px: every 32-px
//        tile's fragility, local and circular variance and coherence from the low-strength residual;
//        its correlation and spread ratio against the point-mirrored tile; its seams against grid
//        neighbours; and the demosaic and spectral columns of the raw pixels. Detection reads their
//        per-image statistics (ResidualStatistics). The signature reads FR alone, through
//        FragilityGrid, which this file does not touch.
//  PIN:  The research's tile extractor, unchanged in order and arithmetic: the 2026-rnd branch's
//        FullGridExtractor.features without the directional signature, with its SeamFeatures and
//        DemosaicFeatures. Pass A runs in ≤256-tile chunks; pass B runs over the whole grid in one
//        graph. The plane caps the longest edge at 512 by Int(Double(w)·scale), draws it with
//        CoreGraphics' default interpolation, and reflect-101 pads it right and bottom to whole
//        tiles. The research's final_mixed tiles were cut this way, and they are this file's oracle.
//

import CoreGraphics
import Foundation
import MLX
import MLXAccelerate
import MLXFFT

/// An image as the tile extractor reads it: capped, padded, [paddedHeight, paddedWidth, 3] in 0–255.
public struct TilePlane {
    public let array: MLXArray
    public let realWidth: Int
    public let realHeight: Int
    public let paddedWidth: Int
    public let paddedHeight: Int

    public static let maxDim = 512

    public init(_ cg: CGImage, maxDim: Int = TilePlane.maxDim) throws {
        var w = cg.width, h = cg.height
        if maxDim > 0, max(w, h) > maxDim {
            let scale = Double(maxDim) / Double(max(w, h))
            (w, h) = (Int(Double(w) * scale), Int(Double(h) * scale))
        }
        guard w > 0, h > 0 else { throw VeilGardeFailure.data("the image is empty") }
        let ts = WarpConstants.tileSize
        let real = try ImageLoading.rgbPixels(cg, width: w, height: h)
        let padW = ((w + ts - 1) / ts) * ts, padH = ((h + ts - 1) / ts) * ts
        var pixels = real
        if padW != w || padH != h {
            let colMap = (0..<padW).map { reflect101Index($0, w) }, rowMap = (0..<padH).map { reflect101Index($0, h) }
            pixels = [Float](repeating: 0, count: padH * padW * 3)
            for i in 0..<padH {
                let si = rowMap[i]
                for j in 0..<padW {
                    let src = (si * w + colMap[j]) * 3, dst = (i * padW + j) * 3
                    pixels[dst] = real[src]; pixels[dst + 1] = real[src + 1]; pixels[dst + 2] = real[src + 2]
                }
            }
        }
        array = MLXArray(pixels, [padH, padW, 3])
        realWidth = w; realHeight = h; paddedWidth = padW; paddedHeight = padH
    }
}

/// Every tile's 19 features, row-major over the tile grid.
public struct TileFeatureRows: Sendable {
    public let tileRows: Int
    public let tileCols: Int
    /// [tileRows · tileCols · 19].
    public let values: [Float]

    public static let featureCount = 19
    public var count: Int { tileRows * tileCols }
}

public enum TileFeatures {
    /// The local-variance box (2×2) and circular-variance box (9×9), the seam strips (4 px) and the
    /// seams' spectral bins (8): the research's constants.
    static let localVarianceKernel = 2, circularVarianceKernel = 9, stripWidth = 4, seamBins = 8

    static func box(_ n: Int) -> MLXArray { MLXArray([Float](repeating: 1.0 / Float(n * n), count: n * n), [n, n]) }

    /// The 19 features of every tile of `plane`.
    public static func measure(_ plane: TilePlane, quantizeLikeCV2: Bool = true) -> TileFeatureRows {
        let img = plane.array, padH = plane.paddedHeight, padW = plane.paddedWidth
        let tables = WarpTables.shared(quantizeLikeCV2: quantizeLikeCV2)
        let lvKernel = box(localVarianceKernel), cvKernel = box(circularVarianceKernel)
        let ts = WarpConstants.tileSize, strip = stripWidth
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
            let lm = batchedFilter2D(Rl, kernel: lvKernel)
            let lm2 = batchedFilter2D(Rl * Rl, kernel: lvKernel)
            let LV = MLX.maximum(lm2 - lm * lm, MLXArray(Float(0))).mean(axes: [1, 2])
            let (gx, gy) = batchedSobelGradients(Rl)
            let ang = MLX.atan2(gy, gx)
            let Rf = MLX.sqrt(batchedFilter2D(MLX.cos(ang), kernel: cvKernel).pow(2) + batchedFilter2D(MLX.sin(ang), kernel: cvKernel).pow(2))
            let cvMap = MLXArray(Float(1.0)) - Rf
            let CV = cvMap.mean(axes: [1, 2])
            // The reference's (|R_l| * (1 - cv_map)).mean(): keep the double rounding, not just Rf.
            let CM = (MLX.abs(Rl) * (MLXArray(Float(1.0)) - cvMap)).mean(axes: [1, 2])
            MLX.eval(Rl, FR, LV, CV, CM)
            RlChunks.append(Rl); FRs.append(FR); LVs.append(LV); CVs.append(CV); CMs.append(CM)
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
        let (SH, SHS) = seams(botS, topS, nr: TR, nc: TC, axis: 1)
        let (SV, SVS) = seams(rgtS, lftS, nr: TR, nc: TC, axis: 2)

        // Demosaic features from the raw channels: the high-pass runs on the whole padded plane.
        let Rch = img[.ellipsis, 0..<1].squeezed(axis: -1).reshaped([1, padH, padW])
        let Gch = img[.ellipsis, 1..<2].squeezed(axis: -1).reshaped([1, padH, padW])
        let Bch = img[.ellipsis, 2..<3].squeezed(axis: -1).reshaped([1, padH, padW])
        let rhT = tileHF(hf3(Rch), TR: TR, TC: TC)
        let ghT = tileHF(hf3(Gch), TR: TR, TC: TC)
        let bhT = tileHF(hf3(Bch), TR: TR, TC: TC)
        let XR = tileXcorr(rhT, ghT), CFA = tileCfa(ghT)
        let ex = extras(rhT, ghT, bhT, Gpl: Gch, padH: padH, padW: padW, TR: TR, TC: TC)

        let featAll = MLX.stacked(
            [MLX.concatenated(FRs, axis: 0), MLX.concatenated(LVs, axis: 0), MLX.concatenated(CVs, axis: 0), MLX.concatenated(CMs, axis: 0),
             CC, CR, SH.reshaped([Ntot]), SV.reshaped([Ntot]), SHS.reshaped([Ntot]), SVS.reshaped([Ntot]),
             XR, CFA, ex.xBG, ex.xRB, ex.cfaR, ex.cfaB, ex.noiseRatio, ex.diagAxial, ex.nyqR],
            axis: 1)
        MLX.eval(featAll)
        return TileFeatureRows(tileRows: TR, tileCols: TC, values: featAll.asArray(Float.self))
    }

    // MARK: Seams (SH, SV, SH_S, SV_S)

    /// How a tile's residual edge strip differs from its neighbour's facing strip, in mean and in
    /// the first 8 rFFT magnitudes. `near` of tile k pairs with `far` of the next tile along `axis`
    /// (1 below, 2 right); the grid's last row or column gets zeros, as in training. Strips are [N, 32].
    static func seams(_ near: MLXArray, _ far: MLXArray, nr: Int, nc: Int, axis: Int) -> (mean: MLXArray, spec: MLXArray) {
        let G = 1
        if (axis == 1 && nr < 2) || (axis == 2 && nc < 2) {
            let z = MLXArray.zeros([G, nr, nc], type: Float.self)
            return (z, z)
        }
        let bins = seamBins
        let nearM = near.mean(axes: [1]).reshaped([G, nr, nc])
        let farM = far.mean(axes: [1]).reshaped([G, nr, nc])
        let nearF = MLX.abs(MLXFFT.rfft(near, axis: 1))[0..., 0..<bins].reshaped([G, nr, nc, bins])
        let farF = MLX.abs(MLXFFT.rfft(far, axis: 1))[0..., 0..<bins].reshaped([G, nr, nc, bins])
        if axis == 1 {
            let zero = MLXArray.zeros([G, 1, nc], type: Float.self)
            let m = MLX.concatenated([MLX.abs(nearM[0..., 0..<(nr - 1), 0...] - farM[0..., 1..., 0...]), zero], axis: 1)
            let s = MLX.concatenated([MLX.abs(nearF[0..., 0..<(nr - 1), 0..., 0...] - farF[0..., 1..., 0..., 0...]).mean(axes: [3]), zero], axis: 1)
            return (m, s)
        } else {
            let zero = MLXArray.zeros([G, nr, 1], type: Float.self)
            let m = MLX.concatenated([MLX.abs(nearM[0..., 0..., 0..<(nc - 1)] - farM[0..., 0..., 1...]), zero], axis: 2)
            let s = MLX.concatenated([MLX.abs(nearF[0..., 0..., 0..<(nc - 1), 0...] - farF[0..., 0..., 1..., 0...]).mean(axes: [3]), zero], axis: 2)
            return (m, s)
        }
    }

    // MARK: Demosaic and spectral columns (11–19), from the raw pixels' 3×3 high-pass

    /// x − the FIXED binomial [0.25, 0.5, 0.25]⊗[0.25, 0.5, 0.25], on [N, H, W]: the reference's
    /// cv2.GaussianBlur(C, (3, 3), 0) uses cv2's small-kernel table, not the exp formula.
    static func hf3(_ x: MLXArray) -> MLXArray {
        let k = MLXArray([0.0625, 0.125, 0.0625,
                          0.125, 0.25, 0.125,
                          0.0625, 0.125, 0.0625] as [Float], [3, 3])
        return x - batchedFilter2D(x, kernel: k)
    }

    /// Per-tile Pearson of two high-pass tile stacks ([N, 32, 32] each).
    static func tileXcorr(_ rh: MLXArray, _ gh: MLXArray) -> MLXArray {
        let N = rh.shape[0], ts = WarpConstants.tileSize
        let A = rh.reshaped([N, ts * ts]), B = gh.reshaped([N, ts * ts])
        let mA = A.mean(axes: [1]), mB = B.mean(axes: [1])
        return ((A * B).mean(axes: [1]) - mA * mB) / (MLX.sqrt(A.variance(axes: [1])) * MLX.sqrt(B.variance(axes: [1])) + Float(1e-6))
    }

    /// Per-tile 2×2 phase-variance spread: (max − min) / mean of the four phase variances.
    static func tileCfa(_ gh: MLXArray) -> MLXArray {
        let N = gh.shape[0], ts = WarpConstants.tileSize
        let ph = gh.reshaped([N, ts / 2, 2, ts / 2, 2])
            .transposed(0, 2, 4, 1, 3)
            .reshaped([N, 4, (ts / 2) * (ts / 2)])
            .variance(axes: [2])
        return (ph.max(axis: 1) - ph.min(axis: 1)) / (ph.mean(axis: 1) + Float(1e-6))
    }

    /// The 32×32 Nyquist checkerboard (−1)^(i+j).
    static func checkerboard() -> MLXArray {
        let ts = WarpConstants.tileSize
        var v = [Float](repeating: 0, count: ts * ts)
        for i in 0..<ts { for j in 0..<ts { v[i * ts + j] = ((i + j) % 2 == 0) ? 1 : -1 } }
        return MLXArray(v, [ts, ts])
    }

    /// Per-tile population std of a high-pass stack → [N].
    static func tileStd(_ x: MLXArray) -> MLXArray {
        let ts = WarpConstants.tileSize
        return MLX.sqrt(x.reshaped([x.shape[0], ts * ts]).variance(axes: [1]))
    }

    /// A [1, H, W] map tiled into [TR·TC, 32, 32], row-major.
    static func tileHF(_ x: MLXArray, TR: Int, TC: Int) -> MLXArray {
        let ts = WarpConstants.tileSize
        return x[0..., 0..<(TR * ts), 0..<(TC * ts)].reshaped([TR, ts, TC, ts]).transposed(0, 2, 1, 3).reshaped([TR * TC, ts, ts])
    }

    /// xcorr_BG, xcorr_RB, cfa_R, cfa_B, noise_ratio, diag_axial, nyq_R per tile. `Gpl` is the RAW
    /// green plane [1, H, W]: diag_axial is a whole-plane gradient ratio, tiled after.
    static func extras(_ rh: MLXArray, _ gh: MLXArray, _ bh: MLXArray, Gpl: MLXArray, padH: Int, padW: Int, TR: Int, TC: Int)
        -> (xBG: MLXArray, xRB: MLXArray, cfaR: MLXArray, cfaB: MLXArray, noiseRatio: MLXArray, diagAxial: MLXArray, nyqR: MLXArray) {
        let N = rh.shape[0], ts = WarpConstants.tileSize
        let noiseRatio = tileStd(rh) / (tileStd(gh) + Float(1e-6))
        let nyqR = MLX.abs((rh * checkerboard()).reshaped([N, ts * ts]).mean(axes: [1]))
        let gx = MLX.abs(Gpl[0..., 0..., 1...] - Gpl[0..., 0..., ..<(padW - 1)])
        let gxP = MLX.concatenated([gx, MLXArray.zeros([1, padH, 1])], axis: 2)
        let dd = MLX.abs(Gpl[0..., 1..., 1...] - Gpl[0..., ..<(padH - 1), ..<(padW - 1)])
        let ddR = MLX.concatenated([dd, MLXArray.zeros([1, padH - 1, 1])], axis: 2)
        let ddP = MLX.concatenated([ddR, MLXArray.zeros([1, 1, padW])], axis: 1)
        let ddTiles = tileHF(ddP, TR: TR, TC: TC).reshaped([N, ts * ts]).mean(axes: [1])
        let gxTiles = tileHF(gxP, TR: TR, TC: TC).reshaped([N, ts * ts]).mean(axes: [1])
        let diagAxial = ddTiles / (gxTiles + Float(1e-6))
        return (tileXcorr(bh, gh), tileXcorr(rh, bh), tileCfa(rh), tileCfa(bh), noiseRatio, diagAxial, nyqR)
    }
}
