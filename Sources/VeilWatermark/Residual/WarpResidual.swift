//
//  WarpResidual.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The warp residual itself: warp every tile through the 16 homographies and back, average the
//        round-trip error over channels and trials, and keep its high frequencies. A camera tile's
//        sensor noise and mosaic do not survive the round trip the way a generator's smooth
//        output does; what is lost is the residual.
//  PIN:  The reference `_warp_noise` for a whole tile batch at once: R = mean_trials mean_channels
//        |tile − back(fwd(tile))|, then R − GaussianBlur(R, 9, σ 1.5) (signed, reflect-101).
//        `tiles` is [N, 1024, 3] in 0–255; the result is [N, 32, 32].
//

import MLX
import MLXAccelerate

public enum WarpResidual {
    public static func batch(_ tiles: MLXArray, forward: WarpTapTable, back: WarpTapTable) -> MLXArray {
        let N = tiles.shape[0]
        let ts = WarpConstants.tileSize
        let warped = applyWarpTable(tiles, forward)                 // [N, 16·1024, 3]
        let returned = applyWarpTable(warped, back)                 // [N, 16·1024, 3]
        let diff = MLX.abs(tiles.reshaped([N, 1, ts * ts, 3]) - returned.reshaped([N, WarpConstants.trials, ts * ts, 3]))
        let R = diff.mean(axes: [3]).mean(axes: [1]).reshaped([N, ts, ts])   // channels, then trials
        return R - batchedGaussianBlur(R, kernelSize: WarpConstants.highPassKernel, sigma: WarpConstants.highPassSigma)
    }

    /// The fragility rate per tile: (mean high-strength residual − mean low-strength) / 0.025.
    public static func fragility(low: MLXArray, high: MLXArray) -> MLXArray {
        (high.mean(axes: [1, 2]) - low.mean(axes: [1, 2])) / (WarpConstants.highStrength - WarpConstants.lowStrength)
    }
}
