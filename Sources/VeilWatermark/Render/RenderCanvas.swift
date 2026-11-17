//
//  RenderCanvas.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The bitmap the digests and overlays are drawn on: an 8-bit device-RGB CoreGraphics context with
//        no alpha, addressed from the top-left, with filled rectangles (opaque or blended), outlines,
//        bitmap-font text and scaled images, and the palette they share. Written out through PNGEncoding.
//  PIN:  Antialiasing off and integer rectangles only, so a digest is the same bytes run to run
//        (RenderTests pins one); only an overlay's scaled photograph goes through interpolation.
//

import CoreGraphics
import Foundation
import VeilGardeCore

struct RenderCanvas {
    struct RGB {
        var r: UInt8, g: UInt8, b: UInt8
        func cg(_ alpha: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, alpha])!
        }
    }

    enum Palette {
        static let background = RGB(r: 18, g: 20, b: 24)
        static let panel = RGB(r: 28, g: 31, b: 37)
        static let text = RGB(r: 232, g: 230, b: 227)
        static let dim = RGB(r: 138, g: 143, b: 152)
        static let accent = RGB(r: 240, g: 138, b: 36)     // the Veil orange
        static let amber = RGB(r: 201, g: 162, b: 39)
        static let agree = RGB(r: 63, g: 185, b: 80)
        static let disagree = RGB(r: 248, g: 81, b: 73)
        static let off = RGB(r: 42, g: 46, b: 53)
        static let masked = RGB(r: 74, g: 79, b: 87)
    }

    let width: Int
    let height: Int
    let context: CGContext

    init(width: Int, height: Int, background: RGB = Palette.background) throws {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw VeilGardeFailure.internalError("cannot create a \(width)×\(height) drawing context")
        }
        ctx.setShouldAntialias(false)
        ctx.interpolationQuality = .high
        // Top-left origin, y down.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        self.width = width
        self.height = height
        context = ctx
        fill(x: 0, y: 0, w: width, h: height, background)
    }

    func fill(x: Int, y: Int, w: Int, h: Int, _ color: RGB, alpha: CGFloat = 1) {
        guard w > 0, h > 0 else { return }
        context.setFillColor(color.cg(alpha))
        context.fill(CGRect(x: x, y: y, width: w, height: h))
    }

    func outline(x: Int, y: Int, w: Int, h: Int, _ color: RGB, thickness: Int = 2) {
        fill(x: x, y: y, w: w, h: thickness, color)
        fill(x: x, y: y + h - thickness, w: w, h: thickness, color)
        fill(x: x, y: y, w: thickness, h: h, color)
        fill(x: x + w - thickness, y: y, w: thickness, h: h, color)
    }

    /// Text with its top-left at (x, y), each font cell `scale` pixels.
    func text(_ string: String, x: Int, y: Int, scale: Int, _ color: RGB) {
        context.setFillColor(color.cg())
        var cx = x
        for ch in string {
            let rows = BitmapFont.glyph(ch)
            for (r, bits) in rows.enumerated() {
                for c in 0..<BitmapFont.glyphWidth where bits & (1 << UInt8(BitmapFont.glyphWidth - 1 - c)) != 0 {
                    context.fill(CGRect(x: cx + c * scale, y: y + r * scale, width: scale, height: scale))
                }
            }
            cx += BitmapFont.advance * scale
        }
    }

    /// Later drawing limited to the rectangle, until `unclip`.
    func clip(x: Int, y: Int, w: Int, h: Int) {
        context.saveGState()
        context.clip(to: CGRect(x: x, y: y, width: w, height: h))
    }

    func unclip() { context.restoreGState() }

    /// `image` drawn into the rectangle (top-left origin), upright.
    func image(_ image: CGImage, x: Int, y: Int, w: Int, h: Int) {
        context.saveGState()
        context.translateBy(x: CGFloat(x), y: CGFloat(y + h))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        context.restoreGState()
    }

    func makeImage() throws -> CGImage {
        guard let image = context.makeImage() else { throw VeilGardeFailure.internalError("cannot finish the drawing") }
        return image
    }

    func png() throws -> Data { try PNGEncoding.png(try makeImage()) }
}
