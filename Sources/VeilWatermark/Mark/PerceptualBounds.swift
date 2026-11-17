//
//  PerceptualBounds.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: How far each pixel of an image may move under the mark: three eighths of the local luma
//        deviation over a 7 × 7 window, at least one level and at most the bound, and never so far
//        that a channel would leave 0–255. Busy texture hides more than flat sky.
//  PIN:  Luma is 0.299 R + 0.587 G + 0.114 B. σ₇ is the population deviation over the 7 × 7 window
//        clipped to the image (integral images in Double). The mark adds one integer to R, G and B
//        alike, so a pixel's room is [−min(b, min channel), min(b, 255 − max channel)]: L∞ ≤ bound by
//        construction and nothing is ever clipped.
//

import Foundation

struct PerceptualBounds {
    let width: Int
    let height: Int
    /// Per pixel, row-major: the lowest and highest offset it may take, inclusive.
    let low: [Int8]
    let high: [Int8]

    /// `rgb` is row-major H × W × 3 in 0–255.
    init(rgb: [Float], width: Int, height: Int, bound: Int) {
        self.width = width
        self.height = height
        let n = width * height
        var luma = [Double](repeating: 0, count: n)
        for i in 0..<n { luma[i] = 0.299 * Double(rgb[3 * i]) + 0.587 * Double(rgb[3 * i + 1]) + 0.114 * Double(rgb[3 * i + 2]) }
        // Integral images of luma and its square, (H+1) × (W+1).
        let stride = width + 1
        var sum = [Double](repeating: 0, count: (height + 1) * stride)
        var squares = [Double](repeating: 0, count: (height + 1) * stride)
        for y in 0..<height {
            var rowSum = 0.0, rowSquares = 0.0
            for x in 0..<width {
                let v = luma[y * width + x]
                rowSum += v
                rowSquares += v * v
                sum[(y + 1) * stride + x + 1] = sum[y * stride + x + 1] + rowSum
                squares[(y + 1) * stride + x + 1] = squares[y * stride + x + 1] + rowSquares
            }
        }
        let cap = max(1, bound)
        var low = [Int8](repeating: 0, count: n), high = [Int8](repeating: 0, count: n)
        for y in 0..<height {
            let y0 = max(0, y - 3), y1 = min(height, y + 4)
            for x in 0..<width {
                let x0 = max(0, x - 3), x1 = min(width, x + 4)
                let count = Double((y1 - y0) * (x1 - x0))
                let s = sum[y1 * stride + x1] - sum[y0 * stride + x1] - sum[y1 * stride + x0] + sum[y0 * stride + x0]
                let q = squares[y1 * stride + x1] - squares[y0 * stride + x1] - squares[y1 * stride + x0] + squares[y0 * stride + x0]
                let mean = s / count
                let sigma = max(0, q / count - mean * mean).squareRoot()
                let b = min(cap, max(1, Int((3 * sigma / 8).rounded())))
                let i = y * width + x
                let lo = min(rgb[3 * i], rgb[3 * i + 1], rgb[3 * i + 2])
                let hi = max(rgb[3 * i], rgb[3 * i + 1], rgb[3 * i + 2])
                low[i] = Int8(-min(b, Int(lo)))
                high[i] = Int8(min(b, 255 - Int(hi)))
            }
        }
        self.low = low
        self.high = high
    }
}
