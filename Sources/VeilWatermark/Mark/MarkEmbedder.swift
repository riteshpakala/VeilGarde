//
//  MarkEmbedder.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Writing the mark: one integer luma offset per pixel, the same on R, G and B, moved a level at a
//        time against the objective's gradient until the tile codes carry the payload's levels; then the
//        marked image is written as PNG, decoded the way any reader decodes it, and read back blind where
//        the mark was written (phase 0, as a reader tries first). What does not read back gets up to two
//        repair rounds; what still does not is reported unverified.
//  PIN:  Each step: the fragility on the embedding grid (the objective and the progress), its gradient,
//        and with the shift term one random grid shift within ±R px (each shifted tile takes the level
//        of the embedding tile holding its centre) at its own margin and weight. The update moves the
//        more influential half of the movable pixels (|∂L/∂δ| at or above the median, by a log₂
//        histogram) one level downhill, inside PerceptualBounds. Pairs short by more than dropFactor
//        margins leave after dropAfter steps. A repair round raises the margin by half. It stops early
//        once every pair on the embedding grid holds its margin.
//

import CoreGraphics
import Foundation
import MLX
import VeilGardeCore
import VeilGardeLens

public struct EmbedReport: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var tiles: Int
    /// Against the source, over R, G and B.
    public var psnr: Double
    public var linf: Int
    public var meanAbsolute: Double
    public var steps: Int
    public var repairs: Int
    /// The share of differing-level pairs on the embedding grid holding their margin, and how many left.
    public var satisfied: Double
    public var droppedPairs: Int
    /// Whether the marked PNG, decoded, reads back as the id.
    public var verified: Bool
    public var pilotZ: Double
    public var codewordAgreement: Double?
    public var seconds: Double
}

enum MarkEmbedder {
    struct Output {
        var rgb: [UInt8]
        var png: Data
        var decoded: CGImage
        var report: EmbedReport
    }

    /// Marks `rgb` (row-major H × W × 3, 0–255) with `id`.
    static func embed(rgb: [Float], width: Int, height: Int, id: WatermarkID, key: WatermarkKey, settings: MarkSettings,
                      options: MarkReadOptions, progress: ((MarkProgress) -> Void)?, cancelled: () -> Bool) throws -> Output {
        let start = Date()
        defer { LensRuntime.releaseMemory() }
        let ts = WarpConstants.tileSize
        let rows = height / ts, cols = width / ts
        guard rows * cols >= PayloadLayout.cells else {
            throw VeilGardeFailure.data("a mark needs at least \(PayloadLayout.cells) full tiles (one 480 × 512 px period); this image has \(rows * cols)")
        }
        let bounds = PerceptualBounds(rgb: rgb, width: width, height: height, bound: settings.bound)
        let layout = PayloadLayout(key: key)
        let cellLevels = layout.levels(for: id, key: key)

        /// Each tile of a grid from (ox, oy) takes the level of the embedding tile holding its centre.
        func levels(originX: Int, originY: Int, rows: Int, cols: Int) -> [Int8] {
            var out = [Int8](repeating: 0, count: rows * cols)
            for r in 0..<rows {
                for c in 0..<cols {
                    let er = (originY + r * ts + ts / 2) / ts, ec = (originX + c * ts + ts / 2) / ts
                    out[r * cols + c] = cellLevels[PayloadLayout.cell(row: er, col: ec)]
                }
            }
            return out
        }

        var objective = FragilityObjective(levels: levels(originX: 0, originY: 0, rows: rows, cols: cols), rows: rows, cols: cols,
                                           margin: settings.margin, weight: 1, sharpness: settings.sharpness)
        let source = MLXArray(rgb, [height, width, 3])
        var delta = [Int8](repeating: 0, count: width * height)
        var rng = SplitMix64(seed: settings.seed ^ id.value)
        var stepsRun = 0, dropped = 0
        var lastShare = 0.0

        func plane() -> MLXArray { source + MLXArray(delta.map { Float($0) }, [height, width, 1]) }

        func runSteps(_ count: Int, stage: MarkProgress.Stage) throws {
            for k in 0..<count {
                if cancelled() { throw CancellationError() }
                let current = plane()
                let fr = TileReads.fragility(current, originX: 0, originY: 0, rows: rows, cols: cols)
                let evaluation = objective.evaluate(fr)
                lastShare = evaluation.share
                progress?(MarkProgress(stage: stage, step: k + 1, steps: count, loss: evaluation.loss, satisfied: evaluation.share,
                                       seconds: Date().timeIntervalSince(start)))
                if evaluation.satisfied == evaluation.active { break }
                if stage == .embedding, k + 1 == settings.dropAfter { dropped += objective.dropHopeless(fr, factor: settings.dropFactor) }
                var gradient = [Float](repeating: 0, count: width * height)
                FragilityGradient.accumulate(current, originX: 0, originY: 0, rows: rows, cols: cols, coefficients: evaluation.coefficients,
                                             width: width, into: &gradient)
                if settings.shiftTerm, settings.shiftRadius > 0 {
                    var dx = 0, dy = 0
                    while dx == 0 && dy == 0 {
                        dx = rng.index(2 * settings.shiftRadius + 1) - settings.shiftRadius
                        dy = rng.index(2 * settings.shiftRadius + 1) - settings.shiftRadius
                    }
                    let ox = ((dx % ts) + ts) % ts, oy = ((dy % ts) + ts) % ts
                    let sr = (height - oy) / ts, sc = (width - ox) / ts
                    let shifted = FragilityObjective(levels: levels(originX: ox, originY: oy, rows: sr, cols: sc), rows: sr, cols: sc,
                                                     margin: settings.shiftMargin, weight: settings.shiftWeight, sharpness: settings.sharpness)
                    let frShift = TileReads.fragility(current, originX: ox, originY: oy, rows: sr, cols: sc)
                    FragilityGradient.accumulate(current, originX: ox, originY: oy, rows: sr, cols: sc, coefficients: shifted.evaluate(frShift).coefficients,
                                                 width: width, into: &gradient)
                }
                if settings.smoothing > 0 { gradient = blur(gradient, width: width, height: height, sigma: settings.smoothing) }
                step(&delta, gradient: gradient, bounds: bounds)
                stepsRun += 1
            }
        }

        try runSteps(settings.steps, stage: .embedding)

        func report(delta: [Int8], rows: Int, cols: Int, reading: MarkReading, verified: Bool) -> EmbedReport {
            var squares = 0.0, absolute = 0.0, linf = 0
            for d in delta {
                let v = Int(d)
                squares += Double(v * v)
                absolute += Double(abs(v))
                linf = max(linf, abs(v))
            }
            let mse = squares / Double(delta.count)
            return EmbedReport(width: width, height: height, tiles: rows * cols, psnr: mse > 0 ? 10 * log10(255 * 255 / mse) : 99,
                               linf: linf, meanAbsolute: absolute / Double(delta.count), steps: stepsRun, repairs: 0, satisfied: lastShare,
                               droppedPairs: dropped, verified: verified, pilotZ: reading.pilotZ, codewordAgreement: reading.codewordAgreement,
                               seconds: Date().timeIntervalSince(start))
        }

        func verify() throws -> (Output, MarkReading) {
            progress?(MarkProgress(stage: .verifying, satisfied: lastShare, seconds: Date().timeIntervalSince(start)))
            var bytes = [UInt8](repeating: 0, count: width * height * 3)
            for i in 0..<(width * height) {
                let d = Float(delta[i])
                for ch in 0..<3 { bytes[3 * i + ch] = UInt8(max(0, min(255, rgb[3 * i + ch] + d))) }
            }
            let png = try PNGEncoding.png(rgb: bytes, width: width, height: height)
            let decoded = try ImageDecoding.cgImage(data: png, name: "the marked image")
            var unsearched = options
            unsearched.search = false
            let reading = MarkDecoder.read(try NativePlane(decoded), key: key, options: unsearched)
            let output = Output(rgb: bytes, png: png, decoded: decoded,
                                report: report(delta: delta, rows: rows, cols: cols, reading: reading, verified: reading.id == id))
            return (output, reading)
        }

        var (output, reading) = try verify()
        var repairs = 0
        while reading.id != id, repairs < settings.repairRounds {
            repairs += 1
            objective.margin = settings.margin * (1 + 0.5 * Float(repairs))
            try runSteps(settings.repairSteps, stage: .repairing)
            (output, reading) = try verify()
        }
        output.report.repairs = repairs
        output.report.seconds = Date().timeIntervalSince(start)
        return output
    }

    /// One level downhill for the more influential half of the movable pixels.
    static func step(_ delta: inout [Int8], gradient: [Float], bounds: PerceptualBounds) {
        // log₂|g| histogram over the movable pixels: 0.1-wide bins over [−60, 20).
        let lowest: Float = -60, width: Float = 0.1, bins = 800
        var histogram = [Int](repeating: 0, count: bins)
        var movable = 0
        for i in gradient.indices {
            let g = gradient[i]
            guard g != 0, g > 0 ? delta[i] > bounds.low[i] : delta[i] < bounds.high[i] else { continue }
            let b = Int((Foundation.log2(abs(g)) - lowest) / width)
            histogram[min(bins - 1, max(0, b))] += 1
            movable += 1
        }
        guard movable > 0 else { return }
        var seen = 0, cut = bins - 1
        for b in stride(from: bins - 1, through: 0, by: -1) {
            seen += histogram[b]
            if seen * 2 >= movable { cut = b; break }
        }
        let threshold = Foundation.exp2(lowest + Float(cut) * width)
        for i in gradient.indices {
            let g = gradient[i]
            guard abs(g) >= threshold else { continue }
            if g > 0, delta[i] > bounds.low[i] { delta[i] -= 1 } else if g < 0, delta[i] < bounds.high[i] { delta[i] += 1 }
        }
    }

    /// A separable Gaussian blur of a row-major H × W field, clamped at the edges.
    static func blur(_ field: [Float], width: Int, height: Int, sigma: Double) -> [Float] {
        let radius = max(1, Int((3 * sigma).rounded(.up)))
        var kernel = (-radius...radius).map { Float(Foundation.exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var tmp = [Float](repeating: 0, count: field.count), out = [Float](repeating: 0, count: field.count)
        for y in 0..<height {
            for x in 0..<width {
                var s: Float = 0
                for k in -radius...radius { s += kernel[k + radius] * field[y * width + min(width - 1, max(0, x + k))] }
                tmp[y * width + x] = s
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var s: Float = 0
                for k in -radius...radius { s += kernel[k + radius] * tmp[min(height - 1, max(0, y + k)) * width + x] }
                out[y * width + x] = s
            }
        }
        return out
    }
}
