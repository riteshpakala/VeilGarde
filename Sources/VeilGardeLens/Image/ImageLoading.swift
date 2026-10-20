//
//  ImageLoading.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A CGImage to the lens's input: an RGB float plane (0–255) after the longest-edge cap,
//        reflect-101 padded right and bottom to a multiple of the patch size, so the tile grid
//        covers the whole image with full, in-distribution 32×32 tiles. Also the native centre
//        crop the domain-shift check scores, and crops rendered as fresh bitmaps.
//  PIN:  Garde's loadImageMLX: the cap truncates `Int(Double(w) · scale)` and resamples with
//        CoreGraphics' default interpolation into an RGBA noneSkipLast context; the pad is always
//        smaller than a patch, so one reflection suffices. renderCrop, never cropping(to:):
//        cropping returns a view with the parent's stride that raw-byte extractors misread
//        (measured by Garde: one interior scored 0.807 as a bitmap and 0.001 as a view).
//

import CoreGraphics
import Foundation
import MLX
import MLXAccelerate

/// The lens's input plane and its geometry.
public struct LoadedImage {
    /// [paddedHeight, paddedWidth, 3], 0–255.
    public let array: MLXArray
    public let realWidth: Int
    public let realHeight: Int
    public let paddedWidth: Int
    public let paddedHeight: Int
}

/// The lens's input before it reaches MLX: the capped, padded RGB plane (0–255), row-major.
public struct PreparedImage: Sendable {
    public let pixels: [Float]
    public let realWidth: Int
    public let realHeight: Int
    public let paddedWidth: Int
    public let paddedHeight: Int
}

public enum ImageLoading {
    /// The image's size after the longest-edge cap (0 = no cap).
    public static func cappedSize(width: Int, height: Int, maxDim: Int) -> (width: Int, height: Int) {
        guard maxDim > 0, max(width, height) > maxDim else { return (width, height) }
        let scale = Double(maxDim) / Double(max(width, height))
        return (Int(Double(width) * scale), Int(Double(height) * scale))
    }

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

    public static func load(_ cgImage: CGImage, maxDim: Int, patchSize: Int) throws -> LoadedImage {
        load(try prepare(cgImage, maxDim: maxDim, patchSize: patchSize))
    }

    /// The CPU half of `load`: decode, cap and pad, no MLX, so it can run on any thread while the
    /// GPU works on another image. `load(prepare(x))` is `load(x)` byte for byte.
    public static func prepare(_ cgImage: CGImage, maxDim: Int, patchSize: Int) throws -> PreparedImage {
        let (w, h) = cappedSize(width: cgImage.width, height: cgImage.height, maxDim: maxDim)
        guard w > 0, h > 0 else { throw VeilGardeFailure.data("the image is empty") }
        let real = try rgbPixels(cgImage, width: w, height: h)
        let padW = ((w + patchSize - 1) / patchSize) * patchSize
        let padH = ((h + patchSize - 1) / patchSize) * patchSize
        if padW == w && padH == h { return PreparedImage(pixels: real, realWidth: w, realHeight: h, paddedWidth: w, paddedHeight: h) }
        let colMap = (0..<padW).map { reflect101Index($0, w) }
        let rowMap = (0..<padH).map { reflect101Index($0, h) }
        var padded = [Float](repeating: 0, count: padH * padW * 3)
        for i in 0..<padH {
            let si = rowMap[i]
            for j in 0..<padW {
                let src = (si * w + colMap[j]) * 3, dst = (i * padW + j) * 3
                padded[dst + 0] = real[src + 0]
                padded[dst + 1] = real[src + 1]
                padded[dst + 2] = real[src + 2]
            }
        }
        return PreparedImage(pixels: padded, realWidth: w, realHeight: h, paddedWidth: padW, paddedHeight: padH)
    }

    /// The GPU half: the prepared plane as an MLX array.
    public static func load(_ prepared: PreparedImage) -> LoadedImage {
        LoadedImage(array: MLXArray(prepared.pixels, [prepared.paddedHeight, prepared.paddedWidth, 3]), realWidth: prepared.realWidth,
                    realHeight: prepared.realHeight, paddedWidth: prepared.paddedWidth, paddedHeight: prepared.paddedHeight)
    }

    /// The native-resolution centre crop (side floored to a multiple of the patch size) the
    /// domain-shift check scores; nil when no cap would apply or the image is too small.
    public static func centerCrop(_ cgImage: CGImage, maxDim: Int, patchSize: Int) -> (array: MLXArray, side: Int)? {
        guard maxDim > 0 else { return nil }
        let W = cgImage.width, H = cgImage.height
        guard max(W, H) > maxDim else { return nil }
        let side = (maxDim / patchSize) * patchSize
        guard side >= patchSize, W >= side, H >= side else { return nil }
        let x0 = (W - side) / 2, y0 = (H - side) / 2
        let bytesPerPixel = 4
        var pixelData = [UInt8](repeating: 0, count: side * side * bytesPerPixel)
        guard let ctx = CGContext(data: &pixelData, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * bytesPerPixel,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // CG's origin is bottom-left: the crop's bottom row sits H − side − y0 above the image bottom.
        ctx.draw(cgImage, in: CGRect(x: -x0, y: -(H - side - y0), width: W, height: H))
        var real = [Float](repeating: 0, count: side * side * 3)
        for i in 0..<side {
            for j in 0..<side {
                let base = (i * side + j) * bytesPerPixel
                real[(i * side + j) * 3 + 0] = Float(pixelData[base + 0])
                real[(i * side + j) * 3 + 1] = Float(pixelData[base + 1])
                real[(i * side + j) * 3 + 2] = Float(pixelData[base + 2])
            }
        }
        return (MLXArray(real, [side, side, 3]), side)
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
