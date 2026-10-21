//
//  ImageLoading.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A CGImage to an RGB float plane (0–255, the given size, top row first), and crops
//        rendered as fresh standalone bitmaps.
//  PIN:  The plane is drawn into an RGBA noneSkipLast context with CoreGraphics' default
//        interpolation. renderCrop, never cropping(to:): cropping returns a view with the parent's
//        stride that raw-byte extractors misread (measured 2026-07: one interior scored 0.807 as a
//        bitmap and 0.001 as a view).
//

import CoreGraphics
import Foundation

public enum ImageLoading {
    /// The RGB bytes of `cgImage` drawn at w × h, top row first, as floats.
    public static func rgbPixels(_ cgImage: CGImage, width w: Int, height h: Int) throws -> [Float] {
        let bytesPerPixel = 4
        var pixelData = [UInt8](repeating: 0, count: w * h * bytesPerPixel)
        guard let ctx = CGContext(data: &pixelData, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * bytesPerPixel,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw VeilGardeFailure.internalError("cannot create a \(w)×\(h) CGContext")
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        var real = [Float](repeating: 0, count: h * w * 3)
        for i in 0..<h {
            for j in 0..<w {
                let base = (i * w + j) * bytesPerPixel
                real[(i * w + j) * 3 + 0] = Float(pixelData[base + 0])
                real[(i * w + j) * 3 + 1] = Float(pixelData[base + 1])
                real[(i * w + j) * 3 + 2] = Float(pixelData[base + 2])
            }
        }
        return real
    }

    /// A crop rendered into a fresh standalone bitmap. `rect` is in image coordinates, origin top-left.
    public static func renderCrop(_ image: CGImage, _ rect: CGRect) -> CGImage? {
        let w = Int(rect.width), h = Int(rect.height)
        guard w > 32, h > 32,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        let dy = CGFloat(image.height) - rect.maxY
        ctx.draw(image, in: CGRect(x: -rect.minX, y: -dy, width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()
    }
}
