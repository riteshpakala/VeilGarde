//
//  SealImage.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The picture a seal reads: drawn over white at a long side of at most 1536 px, a small one
//        drawn up to 768 (at most twice its size), as three float planes 0–255 and its lightness 0–1. Anchors are found here and
//        carried out in the original's pixels, so a seal and a found copy compare in their own units.
//  PIN:  One CoreGraphics draw does the scaling (interpolation high) and the flattening, so a PNG, a
//        JPEG and a picture with alpha read the same pixels. Lightness is HSL's, (max + min) / 2.
//  ROBUSTNESS: Class I · Resizing — every picture is read at the same working size, so a copy resized
//        down from a large original reads nearly the pixels its seal read; a small picture or a small
//        crop drawn up finds anchors at the finest scales it would otherwise lose (SIFT doubles its
//        input for the same reason; a 227 × 339 picture held 14 anchors at its own size, tuning 2026-11-18).
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens

public struct SealImage: Sendable {
    public static let longSide = 1536
    public static let smallLongSide = 768

    public let width: Int
    public let height: Int
    public let originalWidth: Int
    public let originalHeight: Int
    /// Original pixels per working pixel (1 when the picture was read at its own size, below 1 when drawn up).
    public let toOriginal: Double
    public let red: [Float]
    public let green: [Float]
    public let blue: [Float]
    /// HSL lightness, 0–1.
    public let lightness: [Float]

    public init(_ cg: CGImage) throws {
        let long = max(cg.width, cg.height)
        let factor = long > Self.longSide ? Double(Self.longSide) / Double(long)
            : long < Self.smallLongSide ? min(2, Double(Self.smallLongSide) / Double(long)) : 1
        let w = max(1, Int((Double(cg.width) * factor).rounded()))
        let h = max(1, Int((Double(cg.height) * factor).rounded()))
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw VeilGardeFailure.internalError("cannot draw the picture at \(w)×\(h)") }
        var r = [Float](repeating: 0, count: w * h), g = r, b = r, l = r
        for i in 0..<(w * h) {
            let rr = Float(bytes[4 * i]), gg = Float(bytes[4 * i + 1]), bb = Float(bytes[4 * i + 2])
            r[i] = rr
            g[i] = gg
            b[i] = bb
            l[i] = (max(rr, gg, bb) + min(rr, gg, bb)) / 510
        }
        width = w
        height = h
        originalWidth = cg.width
        originalHeight = cg.height
        toOriginal = Double(cg.width) / Double(w)
        red = r
        green = g
        blue = b
        lightness = l
    }
}
