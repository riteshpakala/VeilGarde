//
//  SpectrogramImageTests.swift
//  VeilGardeAudioTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The picture is the lens's own bitmap: flat 8-bit device RGB with R = G = B that
//        ImageLoading.rgbPixels returns byte for byte, that reads back to its levels, and whose
//        PNG decodes through the one image decoder to the same bytes.
//

import CoreGraphics
import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeAudio

@Suite("The picture as a bitmap")
struct SpectrogramImageTests {
    static func seeded(_ profile: SpectrogramProfile, width: Int, seed: UInt64) throws -> SpectrogramImage {
        var rng = SplitMix64(seed: seed)
        return try SpectrogramImage(profile: profile, width: width, gray: (0..<(width * profile.bins)).map { _ in UInt8(rng.index(256)) })
    }

    @Test("flat device RGB, R = G = B, the lens reads the bytes unchanged, and the levels read back", arguments: [SpectrogramProfile.music, .speech])
    func bitmap(profile: SpectrogramProfile) throws {
        let image = try Self.seeded(profile, width: 40, seed: 3)
        let cg = try image.cgImage
        #expect(cg.width == 40 && cg.height == profile.bins && ImageCodec.isFlat(cg))
        let pixels = try ImageLoading.rgbPixels(cg, width: cg.width, height: cg.height)
        var same = true
        for i in image.gray.indices where pixels[i * 3] != Float(image.gray[i]) || pixels[i * 3 + 1] != Float(image.gray[i]) || pixels[i * 3 + 2] != Float(image.gray[i]) { same = false }
        #expect(same, "the lens read other bytes")
        #expect(try SpectrogramImage(cgImage: cg, profile: profile).gray == image.gray)
        #expect(image.level(frame: 7, bin: 1) == image.gray[(profile.bins - 1) * 40 + 7] && image.level(frame: 0, bin: profile.bins) == image.gray[0])
    }

    @Test("the PNG decodes through the image decoder to the same bytes")
    func png() throws {
        let image = try Self.seeded(.speech, width: 64, seed: 11)
        let decoded = try ImageDecoding.cgImage(data: try image.pngData(), name: "a spectrogram PNG")
        #expect(try SpectrogramImage(cgImage: decoded, profile: .speech).gray == image.gray)
    }

    @Test("floor and ceiling shares, and the levels' hash")
    func shares() throws {
        let gray = [UInt8](repeating: 0, count: 512 * 3) + [UInt8](repeating: 255, count: 512)
        let image = try SpectrogramImage(profile: .speech, width: 4, gray: gray)
        #expect(image.floorShare == 0.75 && image.ceilingShare == 0.25 && image.graySHA256 == ContentHash.sha256Hex(Data(gray)))
        #expect(throws: VeilGardeFailure.self) { try SpectrogramImage(profile: .speech, width: 3, gray: gray) }
    }
}
