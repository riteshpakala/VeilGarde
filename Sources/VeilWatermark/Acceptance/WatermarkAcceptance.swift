//
//  WatermarkAcceptance.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Whether v1 works, measured: for each sampled image, a self-match, a random 50%-area crop
//        at a random pixel offset (its match and the offset it recovers), a JPEG q75 re-encode,
//        a cross match of the crop against another image's signature (the false matches), and,
//        on every fourth image, the crop resized to 0.9× and 0.75× (where v1 is expected to
//        break). Then the kill criterion, stated before the run.
//  PIN:  The acceptance, fixed before the run: self-match 100%; the crop matches (score ≥ 0.75, ≥ 256 bits)
//        with its offset within one tile in at least 60% of images; the median JPEG q75 score is
//        at least 0.75; some threshold reaches ≥ 80% crop recall at ≤ 5% cross false matches.
//        Failing any kills v1 (the fallbacks: LV bits, rank-quantized FR). The JPEG keeps the
//        grid in place, so it is matched at phase 0; everything else uses the full phase search.
//        Seeded by SplitMix64; nothing is written but the report and each image's row as it is
//        measured. The resizes are half of an image's cost and no part of the criterion, so on
//        2026-10-19, with the first 24.5 MP image taking 13.5 minutes on a shared GPU, they were
//        cut to every fourth image (decided before any resize was measured). Each image is flattened to the
//        8-bit bitmap the lens reads as soon as it is decoded (ImageCodec), so the crops, the JPEG
//        and the resizes all start from exactly the pixels that were signed.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens

public struct AcceptanceSettings: Codable, Sendable, Equatable {
    public var seed: UInt64 = 0
    public var cropArea = 0.5
    public var jpegQuality = 0.75
    public var scales: [Double] = [0.9, 0.75]
    /// The resizes are measured on every n-th image.
    public var resizeEvery = 4
    public var phases: [Int] = MatchOptions.default.phases
    public var minimumBits = MatchOptions.default.minimumBits
    public var threshold = MatchOptions.default.threshold

    public init() {}

    var options: MatchOptions { MatchOptions(phases: phases, minimumBits: minimumBits, threshold: threshold) }
}

public struct AcceptanceImage: Codable, Sendable {
    public struct Crop: Codable, Sendable { public var x: Int; public var y: Int; public var width: Int; public var height: Int }
    public var path: String
    public var label: Int
    public var width: Int
    public var height: Int
    public var signedBits: Int
    public var balance: [Double]
    public var selfMatch: MatchResult
    public var crop: Crop
    public var cropMatch: MatchResult
    /// The recovered crop origin's distance from the truth, in tiles (the larger axis).
    public var cropOffsetError: Double
    public var jpeg: MatchResult
    public var cross: MatchResult
    public var resized: [String: MatchResult]
    public var seconds: Double
}

public struct AcceptanceSummary: Codable, Sendable {
    public var images: Int
    public var selfMatchRate: Double
    public var cropMatchRate: Double
    public var jpegMedianScore: Double
    public var crossFalseMatchRate: Double
    public var crossMedianScore: Double
    /// The best threshold for crop recall ≥ 80%, and its false-match rate.
    public var operatingThreshold: Double?
    public var operatingRecall: Double?
    public var operatingFalseMatchRate: Double?
    public var bitBalance: [Double]
    public var resizedMatchRate: [String: Double]
    public var killed: Bool
    public var reasons: [String]
}

public struct AcceptanceReport: Codable, Sendable {
    public var settings: AcceptanceSettings
    public var summary: AcceptanceSummary
    public var images: [AcceptanceImage]
}

public enum WatermarkAcceptance {

    public static func run(_ images: [(url: URL, label: Int)], settings: AcceptanceSettings = AcceptanceSettings(),
                           note: (String) -> Void = { _ in }, measured: (AcceptanceImage) -> Void = { _ in }) throws -> AcceptanceReport {
        var rng = SplitMix64(seed: settings.seed)
        let options = settings.options
        // Pass 1: every signature (the cross matches need the next image's).
        var decoded: [(URL, Int, CGImage)] = []
        var signatures: [WatermarkSignature] = []
        for (url, label) in images {
            guard let raw = try? ImageDecoding.cgImage(contentsOf: url), let cg = ImageCodec.flattened(raw), min(cg.width, cg.height) >= 256 else {
                note("accept: skipped \(url.lastPathComponent)"); continue
            }
            decoded.append((url, label, cg))
            signatures.append(try Watermark.sign(cg))
            if signatures.count % 20 == 0 { note("accept: signed \(signatures.count) of \(images.count)") }
        }
        note("accept: signed \(signatures.count) images (\(images.count - signatures.count) skipped); matching")
        var rows: [AcceptanceImage] = []
        for (i, (url, label, cg)) in decoded.enumerated() {
            let started = Date()
            let sig = signatures[i]
            let selfMatch = Watermark.match(codes: try Watermark.phaseCodes(cg, phases: [0]), against: sig, options: options)
            // A crop of half the area, at a random pixel offset.
            let side = settings.cropArea.squareRoot()
            let cw = max(64, Int(Double(cg.width) * side)), ch = max(64, Int(Double(cg.height) * side))
            let x = rng.index(max(1, cg.width - cw + 1)), y = rng.index(max(1, cg.height - ch + 1))
            guard let crop = ImageLoading.renderCrop(cg, CGRect(x: x, y: y, width: cw, height: ch)) else { continue }
            let cropCodes = try Watermark.phaseCodes(crop, phases: settings.phases)
            let cropMatch = Watermark.match(codes: cropCodes, against: sig, options: options)
            let error = Double(max(abs(cropMatch.pixelX - x), abs(cropMatch.pixelY - y))) / 32
            let jpegMatch = Watermark.match(codes: try Watermark.phaseCodes(try ImageCodec.recompressed(cg, as: .jpeg, quality: settings.jpegQuality), phases: [0]),
                                            against: sig, options: options)
            let other = signatures[(i + 1) % signatures.count]
            let cross = Watermark.match(codes: cropCodes, against: other, options: options)
            var resized: [String: MatchResult] = [:]
            for scale in settings.scales where i % max(1, settings.resizeEvery) == 0 {
                guard let r = ImageCodec.resized(crop, by: scale) else { continue }
                resized[String(format: "%.2f", scale)] = Watermark.match(codes: try Watermark.phaseCodes(r, phases: settings.phases), against: sig, options: options)
            }
            let codes = sig.tileCodes
            rows.append(AcceptanceImage(path: url.path, label: label, width: cg.width, height: cg.height, signedBits: sig.measuredBits, balance: codes.balance,
                                        selfMatch: selfMatch, crop: .init(x: x, y: y, width: cw, height: ch), cropMatch: cropMatch, cropOffsetError: error,
                                        jpeg: jpegMatch, cross: cross, resized: resized, seconds: Date().timeIntervalSince(started)))
            measured(rows[rows.count - 1])
            note(String(format: "accept %d/%d %@: self %.3f, crop %.3f (%d bits, off by %.2f tiles), jpeg %.3f, cross %.3f, %.0fs", i + 1, decoded.count,
                        url.lastPathComponent, selfMatch.score, cropMatch.score, cropMatch.bitsCompared, error, jpegMatch.score, cross.score,
                        rows[rows.count - 1].seconds))
        }
        return AcceptanceReport(settings: settings, summary: summarize(rows, settings: settings), images: rows)
    }

    public static func summarize(_ rows: [AcceptanceImage], settings: AcceptanceSettings) -> AcceptanceSummary {
        let n = Double(max(1, rows.count))
        func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
        let selfOK = rows.filter { $0.selfMatch.matched && $0.selfMatch.offsetX == 0 && $0.selfMatch.offsetY == 0 && $0.selfMatch.score == 1 }.count
        let cropOK = rows.filter { $0.cropMatch.matched && $0.cropOffsetError <= 1 }.count
        let crossFalse = rows.filter { $0.cross.matched }.count
        // The operating point: the threshold with crop recall ≥ 80% and the fewest false matches.
        var op: (t: Double, recall: Double, fpr: Double)? = nil
        for k in 50...100 {
            let t = Double(k) / 100
            let recall = Double(rows.filter { $0.cropMatch.score >= t && $0.cropMatch.bitsCompared >= settings.minimumBits && $0.cropOffsetError <= 1 }.count) / n
            let fpr = Double(rows.filter { $0.cross.score >= t && $0.cross.bitsCompared >= settings.minimumBits }.count) / n
            if recall >= 0.80, op == nil || fpr < op!.fpr || (fpr == op!.fpr && t > op!.t) { op = (t, recall, fpr) }
        }
        var balance = [Double](repeating: 0, count: 4)
        for k in 0..<4 { balance[k] = median(rows.map { $0.balance[k] }.filter(\.isFinite)) }
        var resizedRate: [String: Double] = [:]
        for key in Set(rows.flatMap { $0.resized.keys }) {
            let measured = rows.filter { $0.resized[key] != nil }
            resizedRate[key] = Double(measured.filter { $0.resized[key]?.matched == true }.count) / Double(max(1, measured.count))
        }
        let cropRate = Double(cropOK) / n, jpegMedian = median(rows.map(\.jpeg.score))
        var reasons: [String] = []
        if cropRate < 0.60 { reasons.append(String(format: "the crop matched with its offset in %.0f%% of images, under 60%%", cropRate * 100)) }
        if jpegMedian < 0.75 { reasons.append(String(format: "the median JPEG q75 score is %.3f, under 0.75", jpegMedian)) }
        if let op, op.fpr > 0.05 { reasons.append(String(format: "at 80%% crop recall the fewest false matches are %.1f%%, over 5%%", op.fpr * 100)) }
        if op == nil { reasons.append("no threshold reaches 80% crop recall") }
        return AcceptanceSummary(images: rows.count, selfMatchRate: Double(selfOK) / n, cropMatchRate: cropRate, jpegMedianScore: jpegMedian,
                                 crossFalseMatchRate: Double(crossFalse) / n, crossMedianScore: median(rows.map(\.cross.score)),
                                 operatingThreshold: op?.t, operatingRecall: op?.recall, operatingFalseMatchRate: op?.fpr, bitBalance: balance,
                                 resizedMatchRate: resizedRate, killed: !reasons.isEmpty, reasons: reasons)
    }
}
