//
//  ScorerTests.swift
//  VeilGardeLensTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Frigate's XGBoostTreeModel (what the detector scores with) and Core's GBDTModel (what the
//        trainer writes and evaluates) agree bit for bit on the shipped fusion head, missing values
//        included; the decoder applies EXIF orientation as NSImage does.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VeilGardeLens

@Suite("Scorers and decoding")
struct ScorerTests {
    @Test("Frigate's evaluator and GBDTModel agree bit for bit on the shipped fusion head")
    func evaluatorsAgree() throws {
        let url = Fixture.resource("fusion_head.xgb.json")
        let frigate = try TreeModelCache.shared.model(url)
        let core = try GBDTModel.load(url)
        #expect(frigate.numFeatures == core.featureCount)
        var rng = SplitMix64(seed: 7)
        var rows = (0..<32).map { _ in (0..<core.featureCount).map { _ in Float(rng.unit() * 4 - 2) } }
        for i in stride(from: 0, to: rows.count, by: 4) { rows[i][384] = .nan; rows[i][0] = .nan }   // missing values go their default way
        #expect(frigate.predictBatch(rows) == core.scoreBatch(rows))
    }

    /// A 3×2 image whose pixels are all distinct, written with an EXIF orientation tag.
    func orientedPNG(_ orientation: Int) throws -> Data {
        var pixels = [UInt8]()
        for i in 0..<6 { pixels += [UInt8(40 * i), UInt8(255 - 40 * i), UInt8(17 * i), 255] }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func rgb(_ image: CGImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    @Test("orientation 6 rotates clockwise and 1 leaves the pixels alone")
    func orientation() throws {
        let upright = try ImageDecoding.cgImage(data: orientedPNG(1))
        #expect(upright.width == 3 && upright.height == 2)
        let rotated = try ImageDecoding.cgImage(data: orientedPNG(6))
        #expect(rotated.width == 2 && rotated.height == 3)
        let a = rgb(upright), b = rgb(rotated)
        // Rotating 90° clockwise: the stored top-left (0,0) lands at the top-right of a 2-wide image.
        #expect(Array(b[4..<7]) == Array(a[0..<3]))
        // The stored bottom-left (0,1) lands at the top-left.
        #expect(Array(b[0..<3]) == Array(a[12..<15]))
    }
}
