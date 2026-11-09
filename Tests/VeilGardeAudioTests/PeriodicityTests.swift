//
//  PeriodicityTests.swift
//  VeilGardeAudioTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The study's arithmetic, on series with a planted answer: a pulse train of period 21 is a
//        confirmed fundamental and a bare sinusoid a line without harmonics; seeded noise yields no
//        confirmed step; a
//        constant trace is flat; a block planted three times is found by the section scan as a
//        recurrence with its step and phase; the robust statistics and the hypothesis rows.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeAudio

@Suite("The time-phase study's arithmetic")
struct PeriodicityTests {
    static func noise(rows: Int, length: Int, seed: UInt64, amplitude: Double = 1) -> [[Float]] {
        (0..<rows).map { r in
            var rng = SplitMix64(seed: seed ^ UInt64(r + 1))
            return (0..<length).map { _ in Float(amplitude * AudioTransforms.gaussian(&rng)) }
        }
    }

    @Test("a planted pulse train of period 21 is a confirmed fundamental; a bare sinusoid is a line without harmonics")
    func planted() {
        let base = Self.noise(rows: 4, length: 1_200, seed: 3, amplitude: 0.3)
        let pulses = base.map { row in row.enumerated().map { $0.offset % 21 == 0 ? $0.element + 3 : $0.element } }
        let p = PeriodicityScan.scan(pulses, lagMin: 2, columnSeconds: 512 / 44_100, columnSamples: 512)
        #expect(!p.flat && p.rowsUsed == 4 && p.lagMax == 172 && p.nfft == 8_192)
        let step = p.dominant
        #expect(step != nil && abs((step?.period ?? 0) - 21) <= 0.5 && (step?.z ?? 0) >= 4, "\(String(describing: step))")
        #expect(abs((step?.milliseconds ?? 0) - 21 * 512 / 44.1) < 6 && step?.lag == 21)
        #expect(p.steps.count >= 1 && p.steps.allSatisfy(\.fundamental), "fundamentals \(p.steps.map(\.period))")
        #expect(p.peaks.contains { $0.confirmed && abs($0.period - 10.5) <= 0.3 && !$0.fundamental }, "the second harmonic is a confirmed line but not a step")
        let sine = base.map { row in row.enumerated().map { Float(sin(2 * Double.pi * Double($0.offset) / 21)) + $0.element } }
        let q = PeriodicityScan.scan(sine, lagMin: 2, columnSeconds: 512 / 44_100, columnSamples: 512)
        #expect(q.peaks.contains { abs($0.period - 21) <= 0.5 && $0.z >= 4 }, "the sinusoid's line stands out")
        #expect(q.steps.isEmpty && q.dominant == nil, "a sinusoid has no harmonics, so it is no time step: \(q.steps.map(\.period))")
        let probed = PeriodicityScan.scan(pulses, lagMin: 2, columnSeconds: 512 / 44_100, columnSamples: 512, probes: [21, 50])
        #expect(probed.probes.count == 2 && probed.probes[0].z >= 4 && probed.probes[1].z < 4)
    }

    @Test("seeded noise yields no confirmed step, and a constant trace is flat")
    func nulls() {
        let p = PeriodicityScan.scan(Self.noise(rows: 8, length: 1_200, seed: 11), lagMin: 2, columnSeconds: 512 / 44_100, columnSamples: 512)
        #expect(!p.flat && p.steps.isEmpty, "steps on noise: \(p.steps.map(\.period))")
        let flat = PeriodicityScan.scan([[Float]](repeating: [Float](repeating: 0.3, count: 500), count: 3), lagMin: 2, columnSeconds: 0.01, columnSamples: 256)
        #expect(flat.flat && flat.dominant == nil && flat.rowsUsed == 0)
        #expect(PeriodicityScan.robust([1, 2, 3, 4, 100]) == (3, 1))
    }

    @Test("a block planted three times is a recurrence with its step and phase")
    func sections() {
        let profile = SpectrogramProfile.music
        let rows = 4, columns = 700, length = 43
        var fr = Self.noise(rows: rows, length: columns, seed: 5).flatMap { $0 }
        var rng = SplitMix64(seed: 9)
        let block = (0..<(rows * length)).map { _ in Float(3 * AudioTransforms.gaussian(&rng)) }
        for start in [0, 200, 400] {
            for r in 0..<rows { for j in 0..<length { fr[r * columns + start + j] = block[r * length + j] } }
        }
        let trace = FragilityTrace(profile: profile, subHop: 1, rows: rows, frames: columns + 31, columns: columns, pictureColumns: columns + 31, fr: fr,
                                   residual: [Float](repeating: 0, count: rows * (columns + 31)))
        let sets = SectionRecurrence.scan(trace, sectionSeconds: [0.5])
        let first = sets[0].sections[0]
        #expect(sets[0].length == 43 && first.start == 0)
        #expect(first.peaks.map(\.offset) == [200, 400], "peaks at \(first.peaks.map(\.offset))")
        #expect(first.peaks.allSatisfy { $0.similarity > 0.9 && $0.z >= 4 && $0.bitAgreement > 0.9 })
        #expect(first.recurrence == SectionRecurrenceFound(stepColumns: 200, stepSeconds: 200 * 512 / 44_100, phaseColumns: 0, peaks: 3))
        #expect(sets[0].withRecurrence >= 1 && sets[0].sections[1].recurrence == nil)
        #expect(SectionRecurrence.recurrence(start: 10, peaks: [110, 211, 309], columnSeconds: 1) == SectionRecurrenceFound(stepColumns: 100, stepSeconds: 100, phaseColumns: 10, peaks: 4))
        #expect(SectionRecurrence.recurrence(start: 0, peaks: [100], columnSeconds: 1) == nil)
    }

    @Test("the hypothesis rows are the rules', eight of them, and the summary bins the dominant steps")
    func rows() {
        #expect(TimePhaseStudy.rows.map(\.id) == ["P1", "P2", "N1", "B1", "S1", "S2", "M1", "M2"])
        #expect(TimePhaseStudy.rows.allSatisfy { !$0.confirmedWhen.isEmpty && !$0.refutedWhen.isEmpty })
        let flat = Periodicity(lagMin: 2, lagMax: 10, columnSeconds: 0.01, nfft: 64, rowsUsed: 0, flat: true, peaks: [], steps: [], dominant: nil, probes: [], curve: [])
        let peak = PeriodicityPeak(period: 3, lag: 3, samples: 192, milliseconds: 12, power: 0.5, z: 6, confirmed: true, fundamental: true)
        let found = Periodicity(lagMin: 2, lagMax: 10, columnSeconds: 0.004, nfft: 64, rowsUsed: 16, flat: false, peaks: [peak], steps: [peak], dominant: peak, probes: [], curve: [0, 6, 0])
        func report(_ name: String, _ e: Periodicity) -> TimePhaseReport {
            TimePhaseReport(path: name, kind: "synthetic", profile: SpectrogramProfile.speech.record, nativeRate: 16_000, seconds: 12, frames: 751, subHop: 4, traceColumns: 2_880,
                            sections: [], periodicityT: flat, periodicityE: e, flags: TimePhaseFlags(flat: false, recurrence: false, stepUnder20ms: (e.dominant?.milliseconds ?? 99) < 20, codecFrame: nil),
                            reencode: nil, elapsed: 1)
        }
        let s = TimePhaseStudy.summarize([report("a", found), report("b", flat)])
        #expect(s.clips == 2 && s.stepUnder20ms == 1 && s.histogramE == ["10-20": 1, "none": 1] && s.confirmedLagsE["a"] == [3] && s.confirmedLagsE["b"] == [])
        #expect(s.codecFrame == nil && s.reencoded == 0)
    }
}
