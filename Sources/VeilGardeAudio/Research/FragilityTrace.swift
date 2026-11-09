//
//  FragilityTrace.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A clip's fragility dense in time, the time-phase study's instrument: T, the fragility
//        rate of the tile anchored at every frame (the watermark's grid read at all 32 time phases
//        and interleaved), and E, the residual's slope per picture column averaged over the 32
//        tiles that cover it, finer than a tile. At quarter or eighth hops the signal is shifted
//        by a fraction of a hop and the traces interleaved, so the time axis is that much finer.
//  PIN:  T[r, f] is the grid read at phase f mod 32, column f / 32, so T[r, 32c] equals the
//        signature's own grid value (TraceTests). E is the mean over bins of (high − low) / 0.025
//        per tile column, averaged over the tiles covering a picture column; the mean of a tile's
//        32 columns is its fragility rate, so T is E box-filtered over 32 frames. The warps, the
//        strengths, the tile cut and the eval budget are the watermark's own, called through their
//        public surface; nothing is changed or bypassed. Research code: nothing here is read by
//        signing or matching.
//

import CoreGraphics
import Foundation
import MLX
import VeilGardeCore
import VeilGardeLens
import VeilWatermark

public struct FragilityTrace: Sendable, Equatable {
    public let profile: SpectrogramProfile
    /// Columns per frame: 1, 4 or 8.
    public let subHop: Int
    public let rows: Int
    /// The picture's frames, per sub-hop step.
    public let frames: Int
    /// T's columns: (frames − 31) · subHop.
    public let columns: Int
    /// E's columns: frames · subHop.
    public let pictureColumns: Int
    /// T, row-major rows × columns.
    public let fr: [Float]
    /// E, row-major rows × pictureColumns.
    public let residual: [Float]

    /// The time one column stands for.
    public var columnSeconds: Double { Double(profile.hop) / Double(subHop) / profile.sampleRate }
    public var columnSamples: Double { Double(profile.hop) / Double(subHop) }

    public func fr(row: Int, column: Int) -> Float { fr[row * columns + column] }
    public func residual(row: Int, column: Int) -> Float { residual[row * pictureColumns + column] }
    public func frRow(_ row: Int) -> [Float] { Array(fr[(row * columns)..<((row + 1) * columns)]) }
    public func residualRow(_ row: Int) -> [Float] { Array(residual[(row * pictureColumns)..<((row + 1) * pictureColumns)]) }

    /// T at frame resolution: every subHop-th column, phase 0.
    public var frameResolution: FragilityTrace {
        guard subHop > 1 else { return self }
        let tc = columns / subHop, pc = pictureColumns / subHop
        var f = [Float](repeating: 0, count: rows * tc), e = [Float](repeating: 0, count: rows * pc)
        for r in 0..<rows {
            for c in 0..<tc { f[r * tc + c] = fr[r * columns + c * subHop] }
            for c in 0..<pc { e[r * pc + c] = residual[r * pictureColumns + c * subHop] }
        }
        return FragilityTrace(profile: profile, subHop: 1, rows: rows, frames: frames, columns: tc, pictureColumns: pc, fr: f, residual: e)
    }

    /// The trace of one picture at frame resolution: 32 grid reads, interleaved.
    public static func measure(_ image: SpectrogramImage) throws -> FragilityTrace {
        defer { LensRuntime.releaseMemory() }
        let ts = WarpConstants.tileSize
        let plane = try NativePlane(try image.cgImage)
        let rows = plane.height / ts, width = plane.width
        guard width >= ts, rows > 0 else { throw VeilGardeFailure.data("a picture of \(width) frames and \(plane.height) rows holds no full tile") }
        let traceColumns = width - ts + 1
        var fr = [Float](repeating: 0, count: rows * traceColumns)
        var sum = [Double](repeating: 0, count: rows * width)
        var count = [Int](repeating: 0, count: rows * width)
        let tables = WarpTables.shared(quantizeLikeCV2: true)
        let strength = WarpConstants.highStrength - WarpConstants.lowStrength
        for phase in 0..<ts {
            let cols = (width - phase) / ts
            guard cols > 0 else { continue }
            let region = plane.array[0..<(rows * ts), phase..<(phase + cols * ts), 0...]
            let tiles = region.reshaped([rows, ts, cols, ts, 3]).transposed(0, 2, 1, 3, 4).reshaped([rows * cols, ts * ts, 3])
            var a = 0
            while a < rows * cols {
                let b = min(a + WarpConstants.evalTileBudget, rows * cols)
                let chunk = tiles[a..<b]
                let low = WarpResidual.batch(chunk, forward: tables.lowForward, back: tables.lowBack)
                let high = WarpResidual.batch(chunk, forward: tables.highForward, back: tables.highBack)
                let rate = WarpResidual.fragility(low: low, high: high)
                let perColumn = ((high - low) / strength).mean(axes: [1])
                MLX.eval(rate, perColumn)
                let rates = rate.asArray(Float.self), columnValues = perColumn.asArray(Float.self)
                for k in a..<b {
                    let r = k / cols, c = k % cols
                    let f = phase + c * ts
                    fr[r * traceColumns + f] = rates[k - a]
                    for tx in 0..<ts {
                        sum[r * width + f + tx] += Double(columnValues[(k - a) * ts + tx])
                        count[r * width + f + tx] += 1
                    }
                }
                a = b
            }
        }
        var residual = [Float](repeating: 0, count: rows * width)
        for i in residual.indices where count[i] > 0 { residual[i] = Float(sum[i] / Double(count[i])) }
        return FragilityTrace(profile: image.profile, subHop: 1, rows: rows, frames: width, columns: traceColumns, pictureColumns: width, fr: fr, residual: residual)
    }

    /// The trace of a clip under `profile`, at frame resolution or at quarter or eighth hops.
    public static func measure(_ clip: AudioClip, profile: SpectrogramProfile, subHop: Int = 1) throws -> FragilityTrace {
        guard [1, 4, 8].contains(subHop) else { throw VeilGardeFailure.usage("--sub-hop must be 1, 4 or 8, not \(subHop)") }
        let signal = try AnalysisSignal(clip, profile: profile)
        return try measure(signal, subHop: subHop)
    }

    public static func measure(_ signal: AnalysisSignal, subHop: Int = 1) throws -> FragilityTrace {
        guard [1, 4, 8].contains(subHop) else { throw VeilGardeFailure.usage("--sub-hop must be 1, 4 or 8, not \(subHop)") }
        if subHop == 1 { return try measure(SpectrogramImage(Spectrogram(signal))) }
        var traces: [FragilityTrace] = []
        for q in 0..<subHop {
            let delta = q * signal.profile.hop / subHop
            let shifted = AnalysisSignal(profile: signal.profile, samples: Array(signal.samples.dropFirst(delta)))
            traces.append(try measure(SpectrogramImage(Spectrogram(shifted))))
        }
        return interleave(traces)
    }

    /// Traces of the same clip at successive sub-hop shifts, column q of every frame.
    static func interleave(_ traces: [FragilityTrace]) -> FragilityTrace {
        let subHop = traces.count
        let frames = traces.map(\.frames).min() ?? 0
        let rows = traces[0].rows, ts = WarpConstants.tileSize
        let tc = max(0, frames - ts + 1)
        var fr = [Float](repeating: 0, count: rows * tc * subHop)
        var residual = [Float](repeating: 0, count: rows * frames * subHop)
        for (q, t) in traces.enumerated() {
            for r in 0..<rows {
                for f in 0..<tc { fr[(r * tc + f) * subHop + q] = t.fr[r * t.columns + f] }
                for x in 0..<frames { residual[(r * frames + x) * subHop + q] = t.residual[r * t.pictureColumns + x] }
            }
        }
        return FragilityTrace(profile: traces[0].profile, subHop: subHop, rows: rows, frames: frames, columns: tc * subHop, pictureColumns: frames * subHop,
                              fr: fr, residual: residual)
    }
}
