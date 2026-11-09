//
//  TimePhaseStudy.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The time-phase study of one clip and of a corpus: the trace, the sections' recurrences,
//        the periodicity of T and of E, the flags the hypothesis rows read, the AAC re-encode's
//        trace beside the original for the codec-frame row, a figure, and the corpus summary. The
//        hypothesis rows are data here so the record names them as the rules do.
//  PIN:  Rules fixed before any run (ledger decision-148, rules.md in the study's folder). A clip
//        is flagged "stepUnder20ms" when E has a confirmed fundamental under 20 ms, "codecFrame"
//        when the re-encode's E has a confirmed line within 5% of the codec frame's period where
//        the original's z there is under 2. The codec frame is 1024 samples at the clip's native rate,
//        in the profile's columns. No row claims generated against recorded sound: there is no
//        recorded sound from hardware to compare against this phase.
//

import Foundation
import VeilGardeCore

public struct HypothesisRow: Codable, Sendable, Equatable {
    public var id: String
    public var clips: String
    public var expected: String
    public var instrument: String
    public var confirmedWhen: String
    public var refutedWhen: String
}

public struct TimePhaseFlags: Codable, Sendable, Equatable {
    public var flat: Bool
    public var recurrence: Bool
    public var stepUnder20ms: Bool
    public var codecFrame: Bool?
}

public struct TimePhaseReencode: Codable, Sendable, Equatable {
    public var usedKilobitsPerSecond: Int
    public var codecLagColumns: Double
    public var zOriginalAtCodecLag: Double
    public var zReencodeAtCodecLag: Double
    public var periodicityE: Periodicity
}

public struct TimePhaseReport: Codable, Sendable, Equatable {
    public var path: String
    public var kind: String
    public var profile: SpectrogramProfile.Record
    public var nativeRate: Double
    public var seconds: Double
    public var frames: Int
    public var subHop: Int
    public var traceColumns: Int
    public var sections: [SectionSet]
    public var periodicityT: Periodicity
    public var periodicityE: Periodicity
    public var flags: TimePhaseFlags
    public var reencode: TimePhaseReencode?
    public var elapsed: Double
}

public struct TimePhaseSummary: Codable, Sendable {
    public struct Dominant: Codable, Sendable { public var path: String; public var lag: Int?; public var milliseconds: Double?; public var z: Double? }
    public var clips: Int
    public var flat: Int
    public var withRecurrence: Int
    public var stepUnder20ms: Int
    public var codecFrame: Int?
    public var reencoded: Int
    /// The confirmed fundamentals' lags per clip, the raw material every hypothesis row is judged on.
    public var confirmedLagsE: [String: [Int]]
    public var confirmedLagsT: [String: [Int]]
    public var dominantE: [Dominant]
    public var dominantT: [Dominant]
    /// E's dominant steps binned in milliseconds: "<10", "10-20", "20-50", "50-100", "100-300", "300-1000", ">1000", "none".
    public var histogramE: [String: Int]
}

public enum TimePhaseStudy {
    public static let rows: [HypothesisRow] = [
        HypothesisRow(id: "P1", clips: "musicLike seeds 1–5, 12 s, music", expected: "the note grid: 0.25 s = 21.5 frames, multiples 43, 65, 86", instrument: "E, frame", confirmedWhen: "a confirmed peak at 21 or 22 in ≥ 4 of 5", refutedWhen: "fewer"),
        HypothesisRow(id: "P2", clips: "the same, in T", expected: "the same, attenuated to 0.21", instrument: "T", confirmedWhen: "confirmed in T, so T suffices under a tile", refutedWhen: "not confirmed: E is required"),
        HypothesisRow(id: "N1", clips: "whiteNoise seeds 1–5, silence, tone, both profiles", expected: "nothing", instrument: "T and E", confirmedWhen: "no confirmed peak in any", refutedWhen: "any confirmed peak: the z ≥ 4 rule is reported miscalibrated, not raised"),
        HypothesisRow(id: "B1", clips: "10 s excerpts of the masters, AAC 128 kb/s against the original", expected: "the codec frame: 1024 samples at 48 kHz, 7.35 quarter steps, 21.3 ms", instrument: "E, quarter", confirmedWhen: "a confirmed peak at 7–8 in the re-encode, z < 2 there in the original, in ≥ 50% of excerpts", refutedWhen: "absent"),
        HypothesisRow(id: "S1", clips: "the 56 say utterances, speech", expected: "a synthesis step of 8–20 ms, 2–5 quarter steps (a guess about the voices)", instrument: "E, quarter", confirmedWhen: "confirmed in ≥ 50%", refutedWhen: "< 25%"),
        HypothesisRow(id: "S2", clips: "the same, weaker", expected: "unit or frame edges at 5–10 ms; 10 ms = 2.5 steps is testable, 5 ms is not", instrument: "E, quarter", confirmedWhen: "confirmed at 2–3 steps in ≥ 30%", refutedWhen: "nowhere; 5 ms left open"),
        HypothesisRow(id: "M1", clips: "the 3 masters in 30 s segments", expected: "the beat: a dominant step of 300–1000 ms, consistent within a master", instrument: "T and E, frame", confirmedWhen: "the median dominant step per master in that range, MAD ≤ 2 frames", refutedWhen: "otherwise"),
        HypothesisRow(id: "M2", clips: "the same, 10 s excerpts", expected: "nothing confirmed under 20 ms", instrument: "E, quarter", confirmedWhen: "none in ≥ 80% of excerpts", refutedWhen: "≥ 2 masters show one in ≥ 50%: post-processing bleed, reported as such"),
    ]

    /// One clip's report, and its trace for the figure.
    public static func measure(_ clip: AudioClip, path: String, kind: String, profile: SpectrogramProfile, sectionSeconds: [Double] = SectionRecurrence.sectionSeconds,
                               subHop: Int = 1, reencode: Bool = false) throws -> (report: TimePhaseReport, trace: FragilityTrace) {
        let started = Date()
        let trace = try FragilityTrace.measure(clip, profile: profile, subHop: subHop)
        let sections = SectionRecurrence.scan(trace, sectionSeconds: sectionSeconds)
        let codecColumns = 1024 * profile.sampleRate / clip.sampleRate / trace.columnSamples
        let (t, e) = periodicities(trace, probes: reencode ? [codecColumns] : [])
        var flags = TimePhaseFlags(flat: t.flat && e.flat, recurrence: sections.contains { $0.withRecurrence > 0 },
                                   stepUnder20ms: e.steps.contains { $0.milliseconds < 20 }, codecFrame: nil)
        var reencodeReport: TimePhaseReencode? = nil
        if reencode {
            let aac = try AudioConverting.aacRoundTrip(clip, kilobitsPerSecond: profile.aacKilobitsPerSecond)
            let lag = SignalAlignment.lag(of: aac.clip.mono, against: clip.mono)
            let realigned = AudioClip(sampleRate: clip.sampleRate, mono: SignalAlignment.aligned(aac.clip.mono, by: lag, length: clip.frames))
            let (_, eAAC) = periodicities(try FragilityTrace.measure(realigned, profile: profile, subHop: subHop), probes: [codecColumns])
            let zOriginal = e.probes.first?.z ?? 0, zReencode = eAAC.probes.first?.z ?? 0
            let confirmedNear = eAAC.peaks.contains { $0.confirmed && abs($0.period - codecColumns) <= max(1, 0.05 * codecColumns) }
            flags.codecFrame = confirmedNear && zOriginal < PeriodicityScan.harmonicZ
            reencodeReport = TimePhaseReencode(usedKilobitsPerSecond: aac.usedKilobitsPerSecond, codecLagColumns: codecColumns, zOriginalAtCodecLag: zOriginal,
                                               zReencodeAtCodecLag: zReencode, periodicityE: eAAC)
        }
        let report = TimePhaseReport(path: path, kind: kind, profile: profile.record, nativeRate: clip.sampleRate, seconds: clip.seconds, frames: trace.frames, subHop: subHop,
                                     traceColumns: trace.columns, sections: sections, periodicityT: t, periodicityE: e, flags: flags, reencode: reencodeReport,
                                     elapsed: Date().timeIntervalSince(started))
        return (report, trace)
    }

    /// T's periodicity from periods of 32 frames and E's from 2 steps; `probes` are lags whose z is wanted.
    public static func periodicities(_ trace: FragilityTrace, probes: [Double] = []) -> (t: Periodicity, e: Periodicity) {
        let t = PeriodicityScan.scan((0..<trace.rows).map(trace.frRow), lagMin: 32 * trace.subHop, columnSeconds: trace.columnSeconds, columnSamples: trace.columnSamples, probes: probes)
        let e = PeriodicityScan.scan((0..<trace.rows).map(trace.residualRow), lagMin: 2, columnSeconds: trace.columnSeconds, columnSamples: trace.columnSamples, probes: probes)
        return (t, e)
    }

    public static func summarize(_ reports: [TimePhaseReport]) -> TimePhaseSummary {
        func bin(_ ms: Double?) -> String {
            guard let ms else { return "none" }
            switch ms {
            case ..<10: return "<10"
            case ..<20: return "10-20"
            case ..<50: return "20-50"
            case ..<100: return "50-100"
            case ..<300: return "100-300"
            case ..<1000: return "300-1000"
            default: return ">1000"
            }
        }
        var histogram: [String: Int] = [:]
        for r in reports { histogram[bin(r.periodicityE.dominant?.milliseconds), default: 0] += 1 }
        let reencoded = reports.filter { $0.reencode != nil }
        return TimePhaseSummary(
            clips: reports.count, flat: reports.filter(\.flags.flat).count, withRecurrence: reports.filter(\.flags.recurrence).count,
            stepUnder20ms: reports.filter(\.flags.stepUnder20ms).count, codecFrame: reencoded.isEmpty ? nil : reencoded.filter { $0.flags.codecFrame == true }.count,
            reencoded: reencoded.count,
            confirmedLagsE: Dictionary(uniqueKeysWithValues: reports.map { ($0.path, $0.periodicityE.steps.map(\.lag)) }),
            confirmedLagsT: Dictionary(uniqueKeysWithValues: reports.map { ($0.path, $0.periodicityT.steps.map(\.lag)) }),
            dominantE: reports.map { .init(path: $0.path, lag: $0.periodicityE.dominant?.lag, milliseconds: $0.periodicityE.dominant?.milliseconds, z: $0.periodicityE.dominant?.z) },
            dominantT: reports.map { .init(path: $0.path, lag: $0.periodicityT.dominant?.lag, milliseconds: $0.periodicityT.dominant?.milliseconds, z: $0.periodicityT.dominant?.z) },
            histogramE: histogram)
    }

    /// A figure: T with each tile row 8 px tall, E beneath it, and the pooled autocorrelations of T and E as strips, each panel scaled to its own range.
    public static func figure(_ trace: FragilityTrace, t: Periodicity, e: Periodicity) throws -> Data {
        let width = trace.pictureColumns
        let rowHeight = 8, strip = 48, gap = 4
        let height = trace.rows * rowHeight * 2 + strip * 2 + gap * 3
        var gray = [UInt8](repeating: 0, count: width * height)
        func scaled(_ values: [Float]) -> (Float, Float) {
            let finite = values.filter(\.isFinite)
            return (finite.min() ?? 0, finite.max() ?? 1)
        }
        func paint(_ values: [Float], columns: Int, y0: Int) {
            let (lo, hi) = scaled(values)
            let span = hi > lo ? hi - lo : 1
            for r in 0..<trace.rows {
                for x in 0..<min(columns, width) {
                    let level = UInt8(max(0, min(255, ((values[r * columns + x] - lo) / span * 255).rounded())))
                    for dy in 0..<rowHeight { gray[(y0 + r * rowHeight + dy) * width + x] = level }
                }
            }
        }
        paint(trace.fr, columns: trace.columns, y0: 0)
        paint(trace.residual, columns: trace.pictureColumns, y0: trace.rows * rowHeight + gap)
        func curve(_ p: Periodicity, y0: Int) {
            guard let lo = p.curve.min(), let hi = p.curve.max(), hi > lo else { return }
            for (i, v) in p.curve.enumerated() {
                let x = i * (width - 1) / max(1, p.curve.count - 1)
                let h = Int(((v - lo) / (hi - lo) * Double(strip - 1)).rounded())
                for dy in 0...h { gray[(y0 + strip - 1 - dy) * width + x] = 255 }
            }
        }
        curve(t, y0: trace.rows * rowHeight * 2 + gap * 2)
        curve(e, y0: trace.rows * rowHeight * 2 + gap * 3 + strip)
        return try SpectrogramImage.pngData(gray: gray, width: width, height: height)
    }
}
