//
//  DemosaicFeatures.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The six demosaic and three spectral features (columns 11–19): a real sensor's Bayer
//        interpolation leaves correlated chroma, a phase-dependent variance over the 2×2 mosaic,
//        a noise balance between channels, a gradient anisotropy and Nyquist energy that a
//        generator does not reproduce. All are read from the raw pixels' 3×3 high-pass, not the
//        warp residual.
//  PIN:  `hf3` is x − the FIXED binomial [0.25, 0.5, 0.25]⊗[0.25, 0.5, 0.25], because the reference
//        `cv2.GaussianBlur(C, (3, 3), 0)` uses cv2's small-kernel table for σ ≤ 0 and ksize ≤ 7,
//        not the exp formula (Garde's binomial-kernel gotcha). The high-pass runs on the whole
//        padded plane before tiling, as Python blurs the full image. Population variances,
//        1e-6 guards: the reference `_demosaic_feats`.
//

import MLX
import MLXAccelerate

enum DemosaicFeatures {
    /// x − binomial blur, on [N, H, W].
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

    /// The v2.5 extras per tile: xcorr_BG, xcorr_RB, cfa_R, cfa_B, noise_ratio, diag_axial, nyq_R.
    /// `Gpl` is the RAW green plane [1, H, W]: diag_axial is a whole-plane gradient ratio, tiled after.
    static func extras(_ rh: MLXArray, _ gh: MLXArray, _ bh: MLXArray, Gpl: MLXArray, padH: Int, padW: Int, TR: Int, TC: Int)
        -> (xBG: MLXArray, xRB: MLXArray, cfaR: MLXArray, cfaB: MLXArray, noiseRatio: MLXArray, diagAxial: MLXArray, nyqR: MLXArray) {
        let N = rh.shape[0], ts = WarpConstants.tileSize
        let noiseRatio = tileStd(rh) / (tileStd(gh) + Float(1e-6))
        let nyqR = MLX.abs((rh * checkerboard()).reshaped([N, ts * ts]).mean(axes: [1]))
        let gx = MLX.abs(Gpl[0..., 0..., 1...] - Gpl[0..., 0..., ..<(padW - 1)])                   // [1, H, W−1]
        let gxP = MLX.concatenated([gx, MLXArray.zeros([1, padH, 1])], axis: 2)                     // [1, H, W]
        let dd = MLX.abs(Gpl[0..., 1..., 1...] - Gpl[0..., ..<(padH - 1), ..<(padW - 1)])           // [1, H−1, W−1]
        let ddR = MLX.concatenated([dd, MLXArray.zeros([1, padH - 1, 1])], axis: 2)                 // [1, H−1, W]
        let ddP = MLX.concatenated([ddR, MLXArray.zeros([1, 1, padW])], axis: 1)                    // [1, H, W]
        let ddTiles = tileHF(ddP, TR: TR, TC: TC).reshaped([N, ts * ts]).mean(axes: [1])
        let gxTiles = tileHF(gxP, TR: TR, TC: TC).reshaped([N, ts * ts]).mean(axes: [1])
        let diagAxial = ddTiles / (gxTiles + Float(1e-6))
        return (tileXcorr(bh, gh), tileXcorr(rh, bh), tileCfa(rh), tileCfa(bh), noiseRatio, diagAxial, nyqR)
    }
}
