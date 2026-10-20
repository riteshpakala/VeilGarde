//
//  WarpDebug.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The hooks `veilgarde parity warp|dirsig` run against the cv2 fixtures: one tile's
//        high-passed residual maps at both strengths, and an image's 21-value directional
//        signature block.
//

import MLX

public enum WarpDebug {
    /// One 32×32×3 tile (row-major HWC, 0–255) → its low- and high-strength residual maps.
    public static func residualMaps(tileRGB: [Float], quantizeLikeCV2: Bool) -> (low: [Float], high: [Float]) {
        let ts = WarpConstants.tileSize
        let tiles = MLXArray(tileRGB, [1, ts * ts, 3])
        let tables = WarpTables(quantizeLikeCV2: quantizeLikeCV2)
        let low = WarpResidual.batch(tiles, forward: tables.lowForward, back: tables.lowBack)
        let high = WarpResidual.batch(tiles, forward: tables.highForward, back: tables.highBack)
        MLX.eval(low, high)
        return (low.asArray(Float.self), high.asArray(Float.self))
    }

    /// A full RGB image (row-major HWC, sides multiples of 32) → its [TR·TC, 21] signature, flattened.
    public static func directionalSignature(imageRGB: [Float], height: Int, width: Int, quantizeLikeCV2: Bool) -> [Float] {
        let img = MLXArray(imageRGB, [height, width, 3])
        let ts = WarpConstants.tileSize
        let columns = DirectionalProbes.compute(img: img, H: height, W: width, TR: height / ts, TC: width / ts, quantizeLikeCV2: quantizeLikeCV2)
        let block = MLX.stacked(columns, axis: 1)
        MLX.eval(block)
        return block.asArray(Float.self)
    }
}
