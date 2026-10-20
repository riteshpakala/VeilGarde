//
//  ImageDecoding.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Bytes to a CGImage, the way every shipped artifact has seen them: through NSImage, which
//        applies the EXIF orientation (an iPhone photo stored sideways is analysed upright) and,
//        for some sources, re-renders the rotated image in its own colour space.
//  PIN:  Garde loaded every image as NSImage(contentsOf:).cgImage(forProposedRect: nil, …), and
//        the heads, the fusion corpus and the calibration were all computed from Swift features
//        decoded that way. Measured 2026-10-19 against Garde's own runs:
//        on unrotated images NSImage and ImageIO agree byte for byte, but on rotated iPhone JPEGs
//        NSImage renders Display P3 into Generic RGB (bitmap info 8194) and a pixel-exact ImageIO
//        rotation differs by up to 58 levels, moving the capture peak by up to 50 and flipping a
//        weighted verdict. So decoding stays NSImage's, the only AppKit use in Sources
//        (PackageLayeringTests). ImageIO is the fallback only for bytes NSImage cannot read.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO

public enum ImageDecoding {
    public static func cgImage(contentsOf url: URL) throws -> CGImage {
        if let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VeilGardeFailure.data("cannot decode an image from \(url.path)")
        }
        return cg
    }

    public static func cgImage(data: Data, name: String = "image") throws -> CGImage {
        if let image = NSImage(data: data), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VeilGardeFailure.data("cannot decode \(name) as an image")
        }
        return cg
    }

    /// The EXIF orientation of the first frame (1 when absent), for reports.
    public static func orientation(of url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 1 }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }
}
