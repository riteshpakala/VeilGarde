//
//  PNGEncoding.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: 8-bit RGB pixels to PNG bytes, in the colour space the lens reads them back in, so a marked
//        image decodes (ImageDecoding, then ImageLoading.rgbPixels) to exactly the bytes written.
//  PIN:  The image is device RGB, no alpha, 8 bits a channel, written by ImageIO as public.png: drawn back
//        into the lens's device-RGB context it needs no colour conversion, and PNGEncodingTests holds the
//        round trip byte for byte on noise. A source with another profile (Display P3) is marked in the
//        bytes the lens read it as, so its copy is written in those bytes, untagged.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VeilGardeCore

public enum PNGEncoding {
    /// `rgb` is row-major H × W × 3.
    public static func png(rgb: [UInt8], width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, rgb.count == width * height * 3 else {
            throw VeilGardeFailure.data("a \(width)×\(height) RGB image needs \(width * height * 3) bytes, not \(rgb.count)")
        }
        var rgbx = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            rgbx[4 * i] = rgb[3 * i]
            rgbx[4 * i + 1] = rgb[3 * i + 1]
            rgbx[4 * i + 2] = rgb[3 * i + 2]
        }
        guard let provider = CGDataProvider(data: Data(rgbx) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw VeilGardeFailure.internalError("cannot make a \(width)×\(height) CGImage")
        }
        return try png(image)
    }

    /// Any CGImage as PNG bytes.
    public static func png(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw VeilGardeFailure.internalError("cannot create a PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw VeilGardeFailure.internalError("cannot write the PNG") }
        return out as Data
    }
}
