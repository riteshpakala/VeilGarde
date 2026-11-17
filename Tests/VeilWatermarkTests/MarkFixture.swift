//
//  MarkFixture.swift
//  VeilWatermarkTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What the pixel mark's tests share: a record built from a seeded synthetic signature (no GPU),
//        a report to put in it, soft tile levels laid by an id at a given period offset, and RGB bytes
//        read back the way the lens reads them.
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

    /// The bytes the lens reads, rounded back to UInt8.
    static func bytes(_ image: CGImage) throws -> [UInt8] {
        try ImageLoading.rgbPixels(image, width: image.width, height: image.height).map { UInt8($0) }
    }
}
