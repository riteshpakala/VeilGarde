//
//  SpectrogramImage.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The picture the watermark signs: the spectrogram's grey levels, one byte a pixel, frames
//        left to right and the highest kept bin in the top row; the CGImage the lens reads from it
//        unchanged; the way back from such an image; a PNG of it; and the shares of pixels at the
//        floor and at the ceiling.
//  PIN:  Row r holds bin bins − r, so bin 1 is the bottom row; the DC bin is not drawn. The CGImage
//        is an 8-bit DeviceRGB noneSkipLast bitmap with R = G = B, exactly the context
//        ImageLoading.rgbPixels draws into, so the lens reads these bytes and ImageCodec.isFlat is
//        true. The PNG writer lives here through ImageIO: ImageCodec is lossy platform
//        recompression, and the Lens does not change for the audio carrier.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VeilGardeCore
import VeilGardeLens

public struct SpectrogramImage: Sendable, Equatable {
    public let profile: SpectrogramProfile
    /// Frames.
    public let width: Int
    /// The bins kept, 1…N/2.
    public let height: Int
    /// Row-major grey levels, row 0 the highest bin.
    public let gray: [UInt8]

    public init(_ spectrogram: Spectrogram) {
        profile = spectrogram.profile
        width = spectrogram.frames
        height = spectrogram.profile.bins
        let B = spectrogram.bins
        var g = [UInt8](repeating: 0, count: width * height)
        for t in 0..<width {
            for bin in 1...height {
                let k = t * B + bin
                let m = hypot(Double(spectrogram.real[k]), Double(spectrogram.imaginary[k]))
                g[(height - bin) * width + t] = GrayMapping.level(magnitude: m, profile: profile)
            }
        }
        gray = g
    }

    public init(profile: SpectrogramProfile, width: Int, gray: [UInt8]) throws {
        guard width > 0, gray.count == width * profile.bins else {
            throw VeilGardeFailure.data("a \(profile.name) picture of \(width) frames holds \(width * profile.bins) levels, not \(gray.count)")
        }
        self.profile = profile
        self.width = width
        self.height = profile.bins
        self.gray = gray
    }

    /// A flat 8-bit RGB image back to its levels (the red channel), for a picture someone saved.
    public init(cgImage: CGImage, profile: SpectrogramProfile) throws {
        guard cgImage.height == profile.bins else { throw VeilGardeFailure.data("a \(profile.name) picture is \(profile.bins) px tall, not \(cgImage.height)") }
        let pixels = try ImageLoading.rgbPixels(cgImage, width: cgImage.width, height: cgImage.height)
        var g = [UInt8](repeating: 0, count: cgImage.width * cgImage.height)
        for i in g.indices { g[i] = UInt8(pixels[i * 3]) }
        try self.init(profile: profile, width: cgImage.width, gray: g)
    }

    /// The level of `bin` (1…height) at `frame`.
    public func level(frame: Int, bin: Int) -> UInt8 { gray[(height - bin) * width + frame] }

    /// The bitmap the lens reads unchanged: 8-bit DeviceRGB, no alpha, R = G = B.
    public var cgImage: CGImage {
        get throws { try Self.cgImage(gray: gray, width: width, height: height) }
    }

    /// Any grey plane as that bitmap; the study's figures use it too.
    public static func cgImage(gray: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0, gray.count == width * height else { throw VeilGardeFailure.data("a \(width)×\(height) picture needs \(width * height) levels, not \(gray.count)") }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in gray.indices {
            let v = gray[i]
            bytes[i * 4] = v
            bytes[i * 4 + 1] = v
            bytes[i * 4 + 2] = v
        }
        let image: CGImage? = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
        guard let image else { throw VeilGardeFailure.internalError("cannot make a \(width)×\(height) picture") }
        return image
    }

    public func pngData() throws -> Data { try Self.pngData(gray: gray, width: width, height: height) }

    public static func pngData(gray: [UInt8], width: Int, height: Int) throws -> Data {
        let image = try cgImage(gray: gray, width: width, height: height)
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw VeilGardeFailure.internalError("ImageIO has no PNG encoder on this Mac")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw VeilGardeFailure.internalError("the PNG encode failed") }
        return out as Data
    }

    /// The share of pixels at level 0.
    public var floorShare: Double { Double(gray.reduce(0) { $0 + ($1 == 0 ? 1 : 0) }) / Double(max(1, gray.count)) }
    /// The share of pixels at level 255.
    public var ceilingShare: Double { Double(gray.reduce(0) { $0 + ($1 == 255 ? 1 : 0) }) / Double(max(1, gray.count)) }
    /// The SHA-256 of the levels, the pin a test holds.
    public var graySHA256: String { ContentHash.sha256Hex(Data(gray)) }
}
