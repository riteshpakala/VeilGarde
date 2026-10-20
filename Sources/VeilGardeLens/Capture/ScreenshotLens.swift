//
//  ScreenshotLens.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The flat-UI gate's three tells, measured on the image capped at 2048 px: the share of
//        interior pixels with no gradient, the share of perfectly flat 16-px blocks, and the share
//        of the single most common colour.
//  PIN:  Garde's screenshotGate, unchanged (host-side; Python capture_signature.py screenshot_gate).
//

import CoreGraphics
import Foundation

public enum ScreenshotLens {
    public static func gate(_ cgImage: CGImage) -> ScreenshotGate {
        let W = cgImage.width, H = cgImage.height
        guard W >= 32, H >= 32 else { return .none }
        var w = W, h = H
        if max(W, H) > ScreenshotGate.cap {
            let s = Double(ScreenshotGate.cap) / Double(max(W, H))
            w = Int(Double(W) * s); h = Int(Double(H) * s)
        }
        let bpp = 4
        var px = [UInt8](repeating: 0, count: w * h * bpp)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * bpp,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return .none }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var gray = [Float](repeating: 0, count: w * h)
        var hist = [UInt32: Int]()
        hist.reserveCapacity(4096)
        var topCount = 0
        for i in 0..<(w * h) {
            let b = i * bpp
            let r = px[b], gg = px[b + 1], bl = px[b + 2]
            gray[i] = 0.299 * Float(r) + 0.587 * Float(gg) + 0.114 * Float(bl)
            let code = (UInt32(r) << 16) | (UInt32(gg) << 8) | UInt32(bl)
            let c = (hist[code] ?? 0) + 1
            hist[code] = c
            if c > topCount { topCount = c }
        }
        let topColor = Float(topCount) / Float(w * h)

        // grad_zero: interior pixels with |Sobel_x| + |Sobel_y| < 1e-3.
        var flatPx = 0
        for y in 1..<(h - 1) {
            let r0 = (y - 1) * w, r1 = y * w, r2 = (y + 1) * w
            for x in 1..<(w - 1) {
                let gx = -gray[r0 + x - 1] + gray[r0 + x + 1] - 2 * gray[r1 + x - 1] + 2 * gray[r1 + x + 1] - gray[r2 + x - 1] + gray[r2 + x + 1]
                let gy = -gray[r0 + x - 1] - 2 * gray[r0 + x] - gray[r0 + x + 1] + gray[r2 + x - 1] + 2 * gray[r2 + x] + gray[r2 + x + 1]
                if abs(gx) + abs(gy) < 1e-3 { flatPx += 1 }
            }
        }
        let gradZero = Float(flatPx) / Float(w * h)

        // flat_strict: 16×16 blocks with population std < 0.3.
        let bs = 16
        var blocks = 0, flatBlocks = 0
        var y = 0
        while y + bs <= h {
            var x = 0
            while x + bs <= w {
                var m: Float = 0
                for j in 0..<bs { let row = (y + j) * w + x; for k in 0..<bs { m += gray[row + k] } }
                m /= Float(bs * bs)
                var s: Float = 0
                for j in 0..<bs { let row = (y + j) * w + x; for k in 0..<bs { let d = gray[row + k] - m; s += d * d } }
                if (s / Float(bs * bs)).squareRoot() < 0.3 { flatBlocks += 1 }
                blocks += 1
                x += bs
            }
            y += bs
        }
        let flatStrict = blocks > 0 ? Float(flatBlocks) / Float(blocks) : 0
        return ScreenshotGate.decide(gradZero: gradZero, flatStrict: flatStrict, topColor: topColor)
    }
}
