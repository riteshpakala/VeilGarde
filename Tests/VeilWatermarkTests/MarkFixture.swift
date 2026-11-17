//
//  MarkFixture.swift
//  VeilWatermarkTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What the pixel mark's tests share: a record built from a seeded synthetic signature (no GPU),
//        a report to put in it, soft tile levels laid by an id at a given period offset, a 2048 × 1024
//        image composed of the two parity crops (a reading needs about four periods folded, which one
//        crop is far short of), and RGB bytes read back the way the lens reads them.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens
@testable import VeilWatermark

enum MarkFixture {
    static let id = WatermarkID(0x0123_4567_89ab_cdef)

    static func report(verified: Bool = true) -> EmbedReport {
        EmbedReport(width: 512, height: 512, tiles: 256, psnr: 44.25, linf: 3, meanAbsolute: 0.8, steps: 20, repairs: 0, satisfied: 0.93,
                    droppedPairs: 12, verified: verified, pilotZ: 7.5, codewordAgreement: 0.97, seconds: 61)
    }

    static func record(id: WatermarkID = id, label: String? = "Ana", seed: UInt64 = 7, sha: String? = nil) -> SignatureRecord {
        let signature = WatermarkSignature(grid: randomCodes(rows: 16, cols: 16, seed: seed))
        return SignatureRecord(id: id, label: label, keyFingerprint: WatermarkKey.default.fingerprint, signature: signature,
                               pngSHA256: sha ?? ContentHash.sha256Hex("png \(id.hex) \(seed)"), width: 512, height: 512, sourceName: "ana.jpg",
                               createdAt: Date(timeIntervalSince1970: 1_795_000_000), settings: .default, report: report())
    }

    /// Soft levels (±1) on a rows × cols grid whose tile (0, 0) carries period cell (offsetRow, offsetCol).
    static func softGrid(id: WatermarkID, key: WatermarkKey = .default, rows: Int, cols: Int, offsetRow: Int, offsetCol: Int) -> [Float] {
        let levels = PayloadLayout(key: key).levels(for: id, key: key)
        var out = [Float](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            for c in 0..<cols { out[r * cols + c] = Float(levels[PayloadLayout.cell(row: r + offsetRow, col: c + offsetCol)]) }
        }
        return out
    }

    /// A 2048 × 1024 image of the two parity crops, eight ways: as they are and mirrored on the top row, flipped and
    /// turned half round below. A reading needs about four periods folded, so a crop of it still holds enough.
    static func composite() throws -> CGImage {
        let ben = try ImageDecoding.cgImage(contentsOf: Fixture.crop("crop_ben.png"))
        let fox = try ImageDecoding.cgImage(contentsOf: Fixture.crop("crop_fox.png"))
        guard let ctx = CGContext(data: nil, width: 2048, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw VeilGardeFailure.internalError("no context") }
        ctx.interpolationQuality = .none
        /// Draws `image` into the 512² cell (column, row from the top), scaled by (sx, sy) about the cell's centre.
        func cell(_ image: CGImage, _ column: Int, _ row: Int, sx: CGFloat, sy: CGFloat) {
            ctx.saveGState()
            // CoreGraphics draws from the bottom-left: the top row sits at y 512.
            ctx.translateBy(x: CGFloat(column * 512 + 256), y: CGFloat((1 - row) * 512 + 256))
            ctx.scaleBy(x: sx, y: sy)
            ctx.draw(image, in: CGRect(x: -256, y: -256, width: 512, height: 512))
            ctx.restoreGState()
        }
        cell(ben, 0, 0, sx: 1, sy: 1)
        cell(fox, 1, 0, sx: 1, sy: 1)
        cell(ben, 2, 0, sx: -1, sy: 1)
        cell(fox, 3, 0, sx: -1, sy: 1)
        cell(fox, 0, 1, sx: 1, sy: -1)
        cell(ben, 1, 1, sx: 1, sy: -1)
        cell(fox, 2, 1, sx: -1, sy: -1)
        cell(ben, 3, 1, sx: -1, sy: -1)
        guard let image = ctx.makeImage() else { throw VeilGardeFailure.internalError("no image") }
        return image
    }

    /// `image`'s pixels (x, y, w, h from the top-left) as a fresh image.
    static func crop(_ image: CGImage, x: Int, y: Int, w: Int, h: Int) throws -> CGImage {
        guard let out = ImageLoading.renderCrop(image, CGRect(x: x, y: y, width: w, height: h)) else { throw VeilGardeFailure.internalError("no crop") }
        return out
    }

    /// The bytes the lens reads, rounded back to UInt8.
    static func bytes(_ image: CGImage) throws -> [UInt8] {
        try ImageLoading.rgbPixels(image, width: image.width, height: image.height).map { UInt8($0) }
    }
}
