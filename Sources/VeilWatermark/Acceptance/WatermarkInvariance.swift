//
//  WatermarkInvariance.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Whether signing still gives the same signatures: every image signed exactly as
//        `watermark sign` signs it, each signature's content id, grid and measured bits recorded,
//        and a later run compared with a baseline image by image. A change anywhere under the
//        residual a signature is read from shows here as a moved content id.
//  PIN:  The baseline is taken before the change it guards and the comparison re-run after every
//        build; any difference fails (the detector studies of 2026-10-20 took it on the battery's
//        105 images). WatermarkAcceptance measures whether v1 works; this measures only that it
//        has not changed. Nothing is written but the report.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens

public struct InvarianceRow: Codable, Sendable, Equatable {
    public var path: String
    public var fileSHA256: String
    public var width: Int
    public var height: Int
    public var rows: Int
    public var cols: Int
    public var sections: Int
    public var measuredBits: Int
    /// SHA-256 of the signature's binary form.
    public var cid: String
    /// SHA-256 of its vw1 text.
    public var compactSHA256: String
    public var seconds: Double
}

public struct InvarianceReport: Codable, Sendable {
    public var date: Date
    public var coreVersion: String
    public var images: [InvarianceRow]
    public var skipped: [String]
}

public struct InvarianceDifference: Codable, Sendable, Equatable {
    public var path: String
    public var field: String
    public var baseline: String
    public var current: String
}

public enum WatermarkInvariance {
    /// Each image decoded and signed as `watermark sign` does it.
    public static func measure(_ urls: [URL], note: (String) -> Void = { _ in }) -> InvarianceReport {
        var rows: [InvarianceRow] = [], skipped: [String] = []
        for (k, url) in urls.enumerated() {
            let started = Date()
            do {
                let bytes = try Data(contentsOf: url)
                let cg = try ImageDecoding.cgImage(contentsOf: url)
                let sig = try Watermark.sign(cg)
                rows.append(InvarianceRow(path: url.path, fileSHA256: ContentHash.sha256Hex(bytes), width: cg.width, height: cg.height,
                                          rows: sig.rows, cols: sig.cols, sections: sig.codes.count, measuredBits: sig.measuredBits,
                                          cid: sig.cid, compactSHA256: ContentHash.sha256Hex(sig.compact), seconds: Date().timeIntervalSince(started)))
            } catch {
                skipped.append("\(url.path): \(error)")
            }
            if (k + 1) % 25 == 0 { note("invariance: \(k + 1) of \(urls.count) images") }
        }
        return InvarianceReport(date: Date(), coreVersion: VeilGardeVersion.string, images: rows, skipped: skipped)
    }

    /// Every way `current` departs from `baseline`, image by image: a moved file, signature, grid
    /// or bit count, an image no longer signed, or one the baseline does not hold.
    public static func compare(baseline: InvarianceReport, current: InvarianceReport) -> [InvarianceDifference] {
        let now = Dictionary(current.images.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let before = Set(baseline.images.map(\.path))
        var out: [InvarianceDifference] = []
        for b in baseline.images {
            guard let c = now[b.path] else {
                out.append(InvarianceDifference(path: b.path, field: "signed", baseline: "yes", current: "no"))
                continue
            }
            let fields: [(String, String, String)] = [
                ("fileSHA256", b.fileSHA256, c.fileSHA256), ("cid", b.cid, c.cid), ("compactSHA256", b.compactSHA256, c.compactSHA256),
                ("rows", "\(b.rows)", "\(c.rows)"), ("cols", "\(b.cols)", "\(c.cols)"), ("measuredBits", "\(b.measuredBits)", "\(c.measuredBits)"),
            ]
            for (field, x, y) in fields where x != y { out.append(InvarianceDifference(path: b.path, field: field, baseline: x, current: y)) }
        }
        for c in current.images where !before.contains(c.path) {
            out.append(InvarianceDifference(path: c.path, field: "signed", baseline: "absent", current: "yes"))
        }
        return out
    }
}
