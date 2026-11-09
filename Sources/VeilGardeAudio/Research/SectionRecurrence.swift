//
//  SectionRecurrence.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The owner's slicing: a clip's trace cut into sections of a fixed length, each section's
//        block compared with the whole trace at every offset, the offsets that agree, and the
//        recurrences among them, a step and a phase.
//  PIN:  Rules fixed before any run (ledger decision-148): sections start at 0, ℓ, 2ℓ, … on T at
//        frame resolution; S(o) is the Pearson correlation of the two blocks over rows × ℓ, the
//        matcher's bit agreement on codes derived from T beside it; offsets within ℓ + 32 of the
//        section are excluded, since the blocks share a picture column until then; a peak is a
//        local maximum over ±ℓ/2 with z ≥ 4 against the admitted offsets' median and 1.4826·MAD; a
//        recurrence is three or more peaks congruent modulo one spacing Δ within one frame, its
//        phase the section's start modulo Δ. On music a recurrence is a returning phrase: it is
//        labelled "recurrence", never "generated".
//

import Foundation
import VeilWatermark

public struct SectionPeak: Codable, Sendable, Equatable {
    public var offset: Int
    public var seconds: Double
    public var similarity: Double
    public var z: Double
    public var bitAgreement: Double
}

public struct SectionRecurrenceFound: Codable, Sendable, Equatable {
    public var stepColumns: Int
    public var stepSeconds: Double
    public var phaseColumns: Int
    public var peaks: Int
}

public struct SectionReport: Codable, Sendable, Equatable {
    public var start: Int
    public var startSeconds: Double
    public var length: Int
    public var baselineMedian: Double
    public var baselineMAD: Double
    public var peaks: [SectionPeak]
    public var recurrence: SectionRecurrenceFound?
}

public struct SectionSet: Codable, Sendable, Equatable {
    public var seconds: Double
    public var length: Int
    public var sections: [SectionReport]
    public var withRecurrence: Int
}

public enum SectionRecurrence {
    public static let peakZ = 4.0
    public static let sectionSeconds: [Double] = [0.5, 1, 1.5, 2]

    public static func scan(_ trace: FragilityTrace, sectionSeconds: [Double] = sectionSeconds) -> [SectionSet] {
        let t = trace.frameResolution
        let codes = denseCodes(t)
        return sectionSeconds.map { seconds in
            let length = max(1, Int((seconds / t.columnSeconds).rounded()))
            var sections: [SectionReport] = []
            var start = 0
            while start + length <= t.columns {
                sections.append(section(t, codes: codes, start: start, length: length))
                start += length
            }
            return SectionSet(seconds: seconds, length: length, sections: sections, withRecurrence: sections.filter { $0.recurrence != nil }.count)
        }
    }

    /// Four ordinal bits per trace column against the tile 32 frames on, the row below and the two diagonals, masked at the edges.
    static func denseCodes(_ t: FragilityTrace) -> (bits: [UInt8], masks: [UInt8]) {
        let ts = WarpConstants.tileSize
        var bits = [UInt8](repeating: 0, count: t.rows * t.columns), masks = bits
        for r in 0..<t.rows {
            for f in 0..<t.columns {
                let v = t.fr(row: r, column: f)
                for (k, (dr, df)) in [(0, ts), (1, 0), (1, ts), (-1, ts)].enumerated() {
                    let nr = r + dr, nf = f + df
                    guard nr >= 0, nr < t.rows, nf >= 0, nf < t.columns else { continue }
                    masks[r * t.columns + f] |= 1 << k
                    if v > t.fr(row: nr, column: nf) { bits[r * t.columns + f] |= 1 << k }
                }
            }
        }
        return (bits, masks)
    }

    static func section(_ t: FragilityTrace, codes: (bits: [UInt8], masks: [UInt8]), start a: Int, length l: Int) -> SectionReport {
        let rows = t.rows, columns = t.columns, ts = WarpConstants.tileSize
        // The section's block, standardized once.
        var block = [Double](repeating: 0, count: rows * l)
        var meanA = 0.0
        for r in 0..<rows { for j in 0..<l { let v = Double(t.fr(row: r, column: a + j)); block[r * l + j] = v; meanA += v } }
        meanA /= Double(rows * l)
        var varA = 0.0
        for i in block.indices { block[i] -= meanA; varA += block[i] * block[i] }
        let n = Double(rows * l)
        var similarity = [Double](repeating: .nan, count: columns - l + 1)
        var agreement = [Double](repeating: .nan, count: columns - l + 1)
        for o in 0...(columns - l) where abs(o - a) >= l + ts {
            var meanB = 0.0
            for r in 0..<rows { for j in 0..<l { meanB += Double(t.fr(row: r, column: o + j)) } }
            meanB /= n
            var cov = 0.0, varB = 0.0
            var compared = 0, agreed = 0
            for r in 0..<rows {
                for j in 0..<l {
                    let b = Double(t.fr(row: r, column: o + j)) - meanB
                    cov += block[r * l + j] * b
                    varB += b * b
                    let i = r * columns + a + j, k = r * columns + o + j
                    let m = codes.masks[i] & codes.masks[k]
                    compared += m.nonzeroBitCount
                    agreed += (~(codes.bits[i] ^ codes.bits[k]) & m).nonzeroBitCount
                }
            }
            similarity[o] = varA > 0 && varB > 0 ? cov / (varA * varB).squareRoot() : 0
            agreement[o] = compared > 0 ? Double(agreed) / Double(compared) : .nan
        }
        let admitted = similarity.filter { !$0.isNaN }
        let (median, mad) = PeriodicityScan.robust(admitted)
        let scale = mad > 0 ? 1.4826 * mad : .infinity
        var peaks: [SectionPeak] = []
        let half = max(1, l / 2)
        for o in similarity.indices where !similarity[o].isNaN {
            let z = scale.isFinite ? (similarity[o] - median) / scale : 0
            guard z >= peakZ else { continue }
            var isMaximum = true
            for p in max(0, o - half)...min(similarity.count - 1, o + half) where p != o && !similarity[p].isNaN && similarity[p] > similarity[o] { isMaximum = false; break }
            guard isMaximum else { continue }
            peaks.append(SectionPeak(offset: o, seconds: Double(o) * t.columnSeconds, similarity: similarity[o], z: z, bitAgreement: agreement[o]))
        }
        return SectionReport(start: a, startSeconds: Double(a) * t.columnSeconds, length: l, baselineMedian: median, baselineMAD: mad, peaks: peaks,
                             recurrence: recurrence(start: a, peaks: peaks.map(\.offset), columnSeconds: t.columnSeconds))
    }

    /// Three or more peaks congruent modulo one spacing, within one column.
    static func recurrence(start a: Int, peaks: [Int], columnSeconds: Double) -> SectionRecurrenceFound? {
        let offsets = ([a] + peaks).sorted()
        guard offsets.count >= 3 else { return nil }
        var spacings = Set<Int>()
        for i in 1..<offsets.count { spacings.insert(offsets[i] - offsets[i - 1]) }
        var best: SectionRecurrenceFound? = nil
        for step in spacings.sorted() where step > 1 {
            let count = offsets.filter { o in
                let residue = ((o - a) % step + step) % step
                return residue <= 1 || residue >= step - 1
            }.count
            if count >= 3, best == nil || count > best!.peaks {
                best = SectionRecurrenceFound(stepColumns: step, stepSeconds: Double(step) * columnSeconds, phaseColumns: ((a % step) + step) % step, peaks: count)
            }
        }
        return best
    }
}
