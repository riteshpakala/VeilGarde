//
//  ImageCodec.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: An image recompressed in memory, the way a platform recompresses an upload: encoded as
//        JPEG or HEIC at a quality through ImageIO and decoded back the way every image here is
//        decoded, and an image resized through CoreGraphics; first of all, an image flattened to
//        the 8-bit device-RGB bitmap every lens reads. The noiseprint trainer's degradations and
//        the watermark's acceptance run are built on it.
//  PIN:  ImageIO's quality scale is its own: 0.75 here is not libjpeg's q75, which is what the
//        cv2 recipes meant. macOS ImageIO has no WebP encoder, so HEIC stands in wherever the
//        recipes call for WebP, and the stand-in is named wherever it is used. The resize draws
//        with high-quality interpolation into 8-bit device RGB (cv2's INTER_AREA has no
//        CoreGraphics twin). Encoding always starts from the flattened bitmap: an iPhone photo
//        decodes to 10 bits per channel, and on 2026-10-19 one such 24.5 MP image, encoded long
//        after its decode in a process that had run MLX for minutes, sat in
//        CGImageDestinationFinalize for over five minutes while the GPU was saturated (in a fresh
//        process the same encode takes 0.48 s). Flattened, it encodes in 0.06 s, and the lens reads
//        the same pixels either way, since it draws into the same bitmap. Nothing touches the disk.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VeilGardeCore

public enum ImageCodec {
    public enum Format: String, Sendable, Codable, CaseIterable {
        case jpeg, heic

        var identifier: String { (self == .jpeg ? UTType.jpeg : UTType.heic).identifier }
    }

    /// `cg` drawn into an 8-bit device-RGB bitmap with no alpha: exactly the pixels
    /// ImageLoading.rgbPixels reads, so flattening first changes nothing a lens measures.
    public static func flattened(_ cg: CGImage) -> CGImage? {
        if isFlat(cg) { return cg }
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage()
    }

    /// Already an 8-bit device-RGB bitmap without alpha.
    public static func isFlat(_ cg: CGImage) -> Bool {
        cg.bitsPerComponent == 8 && cg.bitsPerPixel == 32 && cg.alphaInfo == .noneSkipLast
            && cg.colorSpace.map { CFEqual($0, CGColorSpaceCreateDeviceRGB()) } == true
    }

    /// Whether this Mac's ImageIO can write `format`.
    public static func canEncode(_ format: Format) -> Bool {
        ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains(format.identifier)
    }

    /// `cg`, flattened, encoded as `format` at `quality` in 0…1.
    public static func encode(_ cg: CGImage, as format: Format, quality: Double) throws -> Data {
        guard let flat = flattened(cg) else { throw VeilGardeFailure.internalError("cannot flatten a \(cg.width)×\(cg.height) image") }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, format.identifier as CFString, 1, nil) else {
            throw VeilGardeFailure.internalError("ImageIO has no \(format.rawValue) encoder on this Mac")
        }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw VeilGardeFailure.internalError("the \(format.rawValue) encode failed") }
        return out as Data
    }

    /// `cg` after a round trip through `format` at `quality`.
    public static func recompressed(_ cg: CGImage, as format: Format, quality: Double) throws -> CGImage {
        try ImageDecoding.cgImage(data: try encode(cg, as: format, quality: quality), name: "a \(format.rawValue) re-encode")
    }

    /// `cg` drawn at `width` × `height`.
    public static func resized(_ cg: CGImage, width: Int, height: Int) -> CGImage? {
        let w = max(1, width), h = max(1, height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// `cg` scaled by `factor`, each side rounded.
    public static func resized(_ cg: CGImage, by factor: Double) -> CGImage? {
        resized(cg, width: Int((Double(cg.width) * factor).rounded()), height: Int((Double(cg.height) * factor).rounded()))
    }
}
