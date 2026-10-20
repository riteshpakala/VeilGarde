//
//  SeamFeatures.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The seam features (SH, SV, SH_S, SV_S): how a tile's residual edge strip differs from its
//        neighbour's facing strip, in mean and in the first 8 rFFT magnitudes. Generated content
//        stitched from latent patches leaves seams a single sensor read does not.
//  PIN:  `near` of tile k pairs with `far` of the next tile along `axis` (1 below, 2 right); the
//        grid's last row or column gets zeros, as in training. Strips are [N, 32].
//

import MLX
import MLXFFT

enum SeamFeatures {
    static func compute(_ near: MLXArray, _ far: MLXArray, G: Int, nr: Int, nc: Int, axis: Int) -> (mean: MLXArray, spec: MLXArray) {
        if (axis == 1 && nr < 2) || (axis == 2 && nc < 2) {
            let z = MLXArray.zeros([G, nr, nc], type: Float.self)
            return (z, z)
        }
        let bins = WarpConstants.seamBins
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
}
