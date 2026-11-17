//
//  PNGEncodingTests.swift
//  VeilWatermarkTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The marked image's way out and back: RGB noise (and every level of every channel) written as
//        PNG and decoded the way any reader here decodes it comes back byte for byte, so a mark is never
//        moved by its own file.
//

import CoreGraphics
import Foundation
import Testing
import VeilGardeCore
import VeilGardeLens
@testable import VeilWatermark

@Suite("PNG encoding")
struct PNGEncodingTests {
    @Test("noise survives the PNG and the decoder byte for byte", arguments: [(97, 61), (512, 512), (33, 1000)])
    func noiseRoundTrip(size: (Int, Int)) throws {
        let (w, h) = size
        var rng = SplitMix64(seed: UInt64(w * 7919 + h))
        let rgb = (0..<(w * h * 3)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let png = try PNGEncoding.png(rgb: rgb, width: w, height: h)
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let back = try ImageDecoding.cgImage(data: png, name: "noise")
        #expect(back.width == w && back.height == h)
        #expect(try MarkFixture.bytes(back) == rgb)
    }

    @Test("every level of every channel survives")
    func everyLevel() throws {
        var rgb: [UInt8] = []
        for v in 0..<256 {
            rgb += [UInt8(v), 0, 0, 0, UInt8(v), 0, 0, 0, UInt8(v), UInt8(v), UInt8(255 - v), UInt8(v / 2)]
        }
        let png = try PNGEncoding.png(rgb: rgb, width: 4, height: 256)
        #expect(try MarkFixture.bytes(try ImageDecoding.cgImage(data: png)) == rgb)
    }

    @Test("a wrong byte count is refused")
    func refuses() {
        #expect(throws: (any Error).self) { _ = try PNGEncoding.png(rgb: [1, 2, 3], width: 2, height: 2) }
    }
}
