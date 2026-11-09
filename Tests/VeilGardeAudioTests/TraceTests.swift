//
//  TraceTests.swift
//  VeilGardeAudioTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The fragility trace on the GPU: its tile-boundary columns are the signature's own grid,
//        exactly; a stationary tone gives the same fragility at every phase and the same residual
//        per column, so the interleave scrambles nothing; the quarter-hop trace carries the frame
//        trace in its phase-0 columns.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeAudio

extension AudioMLXSuites {
    @Suite("The fragility trace on the GPU", .serialized)
    struct TraceOnGPU {
        static let clip = SyntheticClips.musicLike(seed: 1, seconds: 6, sampleRate: 44_100)

        @Test("T at the tile boundaries is the signature's own grid, exactly, and E averages to T")
        func boundaries() throws {
            let profile = SpectrogramProfile.music
            let image = try AudioWatermark.picture(Self.clip, profile: profile)
            let trace = try FragilityTrace.measure(image)
            let grid = try AudioWatermark.fragility(image)
            #expect(trace.rows == 32 && trace.rows == grid.rows && trace.frames == image.width && trace.columns == image.width - 31 && trace.pictureColumns == image.width)
            var same = true
            for r in 0..<grid.rows { for c in 0..<grid.cols where trace.fr(row: r, column: 32 * c) != grid[r, c] { same = false } }
            #expect(same, "a tile-boundary column of the trace differs from the grid")
            // The interior of E and the interior of T both average the residual's slope; their means agree closely.
            var meanE = 0.0, meanT = 0.0
            let interior = 31..<(trace.pictureColumns - 31)
            for r in 0..<trace.rows {
                for x in interior { meanE += Double(trace.residual(row: r, column: x)) }
                for f in 31..<(trace.columns - 31) { meanT += Double(trace.fr(row: r, column: f)) }
            }
            meanE /= Double(trace.rows * interior.count)
            meanT /= Double(trace.rows * (trace.columns - 62))
            #expect(abs(meanE - meanT) <= 0.05 * abs(meanT), "E's interior mean \(meanE), T's \(meanT)")
        }

        @Test("a stationary tone gives one fragility at every phase and one residual per column")
        func tone() throws {
            let profile = SpectrogramProfile.speech
            let tone = SyntheticClips.tone(frequency: 1_000, amplitude: 0.5, seconds: 4, sampleRate: profile.sampleRate)
            let trace = try FragilityTrace.measure(tone, profile: profile)
            var constant = true, residualAgrees = true
            for r in 0..<trace.rows {
                let reference = trace.fr(row: r, column: 2)
                for f in 2..<(trace.columns - 2) where trace.fr(row: r, column: f) != reference { constant = false }
                for x in 33..<(trace.pictureColumns - 33) where abs(trace.residual(row: r, column: x) - reference) > 1e-4 { residualAgrees = false }
            }
            #expect(constant, "T moved along a stationary tone")
            #expect(residualAgrees, "E's interior differs from the tile's fragility on a stationary tone")
        }

        @Test("the quarter-hop trace carries the frame trace in its phase-0 columns, four times as wide")
        func quarterHop() throws {
            let profile = SpectrogramProfile.music
            let frame = try FragilityTrace.measure(Self.clip, profile: profile)
            let quarter = try FragilityTrace.measure(Self.clip, profile: profile, subHop: 4)
            #expect(quarter.subHop == 4 && quarter.columns == 4 * (quarter.frames - 31) && quarter.frames <= frame.frames && quarter.frames >= frame.frames - 1)
            #expect(abs(quarter.columnSeconds * 4 - frame.columnSeconds) < 1e-12)
            var same = true
            for r in 0..<frame.rows { for f in 0..<(quarter.frames - 31) where quarter.fr(row: r, column: 4 * f) != frame.fr(row: r, column: f) { same = false } }
            #expect(same, "the quarter-hop trace's phase-0 columns differ from the frame trace")
            #expect(quarter.frameResolution.fr == Array(frame.fr.enumerated().filter { ($0.offset % frame.columns) < quarter.frames - 31 }.map(\.element)))
        }
    }
}
