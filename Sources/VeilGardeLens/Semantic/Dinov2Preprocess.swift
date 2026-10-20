//
//  Dinov2Preprocess.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A CGImage to the (1, 224, 224, 3) tensor DINOv2 reads: shortest edge to 256 with high
//        quality interpolation, centre crop 224, /255, ImageNet mean and std. The specialist heads'
//        variant first force-resizes the image to 360×640, so the source resolution cannot leak
//        into the embedding (phone screenshots are huge, the training reels were small).
//  PIN:  Garde's Dinov2Preprocess (HF BitImageProcessor replica). The fusion head reads the plain
//        path; every linear head reads the force-resized one: two different embeddings of one
//        image, and the store keeps both (dino_fusion, dino_norm).
//

import CoreGraphics
import Foundation
import MLX

public enum Dinov2Preprocess {
    static let mean: [Float] = [0.485, 0.456, 0.406]
    static let std: [Float] = [0.229, 0.224, 0.225]

    /// Row 0 is the image's top: a bitmap context stores it so, and `draw` renders upright.
    public static func input(_ cg: CGImage, target: Int = 224, shortEdge: Int = 256) -> MLXArray {
        let w = cg.width, h = cg.height
        let scale = Double(shortEdge) / Double(min(w, h))
        let sw = Double(w) * scale, sh = Double(h) * scale
        let cropX = (sw - Double(target)) / 2.0
        let cropY = (sh - Double(target)) / 2.0
        var buf = [UInt8](repeating: 0, count: target * target * 4)
        guard let ctx = CGContext(data: &buf, width: target, height: target, bitsPerComponent: 8, bytesPerRow: target * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return MLXArray.zeros([1, target, target, 3])
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: -cropX, y: -cropY, width: sw, height: sh))
        var floats = [Float](repeating: 0, count: target * target * 3)
        for i in 0..<(target * target) {
            floats[i * 3 + 0] = (Float(buf[i * 4 + 0]) / 255.0 - mean[0]) / std[0]
            floats[i * 3 + 1] = (Float(buf[i * 4 + 1]) / 255.0 - mean[1]) / std[1]
            floats[i * 3 + 2] = (Float(buf[i * 4 + 2]) / 255.0 - mean[2]) / std[2]
        }
        return MLXArray(floats, [1, target, target, 3])
    }

    /// The heads' input: force-resize to normW × normH (aspect not kept, PIL's resize), then `input`.
    public static func inputNormalized(_ cg: CGImage, normW: Int = 360, normH: Int = 640, target: Int = 224, shortEdge: Int = 256) -> MLXArray {
        guard let r = resizeExact(cg, normW, normH) else { return input(cg, target: target, shortEdge: shortEdge) }
        return input(r, target: target, shortEdge: shortEdge)
    }

    static func resizeExact(_ cg: CGImage, _ w: Int, _ h: Int) -> CGImage? {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
