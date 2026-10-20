//
//  Gray.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: cv2's uint8 gray, the texture weight's input: cvtColor(RGB2GRAY) on uint8 data is
//        (R·4899 + G·9617 + B·1868 + 8192) >> 14.
//  PIN:  The inputs hold exact uint8 values in float32 and every intermediate stays below 2^24, so
//        this floor-division reproduces cv2's rounded gray bit for bit.
//

import MLX

enum Gray {
    static func cv2U8(_ img: MLXArray) -> MLXArray {
        let r = img[.ellipsis, 0..<1].squeezed(axis: -1)
        let g = img[.ellipsis, 1..<2].squeezed(axis: -1)
        let b = img[.ellipsis, 2..<3].squeezed(axis: -1)
        return MLX.floor((r * Float(4899) + g * Float(9617) + b * Float(1868) + Float(8192)) / Float(16384))
    }
}
