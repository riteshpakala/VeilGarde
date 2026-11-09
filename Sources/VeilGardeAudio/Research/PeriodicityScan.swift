//
//  PeriodicityScan.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The recurring time steps in a trace: each row standardized and freed of its slow drift,
//        windowed and transformed, the rows' power spectra pooled, and the spectral lines that
//        stand above a running baseline, confirmed by their harmonics. A confirmed line with no
//        confirmed line at half or a third of its frequency is a fundamental: a time step. The
//        dominant step is the strongest fundamental.
//  PIN:  Rules fixed before any run (ledger decision-148, amended before the first run when the
//        planted-sinusoid test showed a robust z on the autocorrelation cannot see a clean period,
//        since the autocorrelation of a periodic series is itself periodic and its spread swamps
//        the peak). A centred moving average of 4 s is subtracted, a periodic Hann applied, the
//        series zero-padded to four times its length and transformed on Frigate's FFT; the power
//        is pooled as the mean over rows with spread, and rows of zero spread, under one part in
//        ten thousand of their level, are skipped; a trace with none left is flat. Only periods between the shortest and longest lag are read. The
//        power is read in the log, where its noise is near symmetric; the baseline is the running
//        median over ±2.5% of the band, eight bins at least; z = (log power − baseline) / the
//        larger of 1.4826·MAD of that residual over the band and 1/√rows, the log power's own
//        noise when the rows average (a band smooth enough for the running median to reproduce it
//        would otherwise read a zero spread). A line is a local maximum with z ≥ 4; it is confirmed when its second
//        harmonic, and its third where it fits in the band, are local maxima with z ≥ 2 within 1%
//        of their bin, two bins at least. A confirmed line within that tolerance of an integer
//        multiple of a lower confirmed line's bin is a harmonic, not a fundamental. A period is read
//        as nfft / bin, in columns.
//

import Foundation
import MLX
import VeilGardeLens

public struct PeriodicityPeak: Codable, Sendable, Equatable {
    /// The period in columns, nfft / bin, and its rounding.
    public var period: Double
    public var lag: Int
    public var samples: Double
    public var milliseconds: Double
    public var power: Double
    public var z: Double
    public var confirmed: Bool
    /// Confirmed, and not itself the harmonic of a confirmed line: a time step.
    public var fundamental: Bool
}

public struct PeriodicityProbe: Codable, Sendable, Equatable {
    public var lag: Double
    public var z: Double
}

public struct Periodicity: Codable, Sendable, Equatable {
    public var lagMin: Int
    public var lagMax: Int
    public var columnSeconds: Double
    public var nfft: Int
    public var rowsUsed: Int
    public var flat: Bool
    /// Every line with z ≥ 2, so the harmonics a reader confirms a line by are on record.
    public var peaks: [PeriodicityPeak]
    /// The confirmed fundamentals, shortest first.
    public var steps: [PeriodicityPeak]
    /// The strongest fundamental.
    public var dominant: PeriodicityPeak?
    /// z at the lags asked for.
    public var probes: [PeriodicityProbe]
    /// z over the band at 512 points from the longest period to the shortest, for the figure.
    public var curve: [Double]
}

public enum PeriodicityScan {
    public static let peakZ = 4.0
    public static let harmonicZ = 2.0
    public static let longestLagSeconds = 2.0
    public static let smoothingSeconds = 4.0
    public static let padding = 4
    public static let curvePoints = 512

    /// `series` is one array per row of equal length; `columnSeconds` and `columnSamples` convert a lag; `probes` are lags whose z is wanted.
    public static func scan(_ series: [[Float]], lagMin: Int, columnSeconds: Double, columnSamples: Double, probes: [Double] = [],
                            longestLagSeconds: Double = longestLagSeconds, smoothingSeconds: Double = smoothingSeconds) -> Periodicity {
        let length = series.first?.count ?? 0
        let lagMax = min(length / 2, Int(longestLagSeconds / columnSeconds))
        var nfft = 1
        while nfft < length * padding { nfft <<= 1 }
        func empty(flat: Bool, used: Int) -> Periodicity {
            Periodicity(lagMin: lagMin, lagMax: lagMax, columnSeconds: columnSeconds, nfft: nfft, rowsUsed: used, flat: flat, peaks: [], steps: [], dominant: nil,
                        probes: probes.map { PeriodicityProbe(lag: $0, z: 0) }, curve: [])
        }
        guard lagMax > lagMin, length > 2 * lagMin else { return empty(flat: false, used: 0) }
        let window = max(3, Int(smoothingSeconds / columnSeconds) | 1)
        let hann = (0..<length).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(length)) }
        var rows: [Float] = []
        var used = 0
        for row in series {
            guard let detrended = prepared(row, window: window) else { continue }
            used += 1
            var padded = [Float](repeating: 0, count: nfft)
            for i in 0..<length { padded[i] = Float(detrended[i] * hann[i]) }
            rows.append(contentsOf: padded)
        }
        guard used > 0 else { return empty(flat: true, used: 0) }
        let power: [Double] = {
            defer { LensRuntime.releaseMemory() }
            let x = MLXFFT.rfft(MLXArray(rows, [used, nfft]), axis: 1)
            let re = x.realPart(), im = x.imaginaryPart()
            let p = (re * re + im * im).mean(axes: [0])
            MLX.eval(p)
            return p.asArray(Float.self).map(Double.init)
        }()
        // The band: bins whose period nfft / b lies between lagMin and lagMax.
        let bLo = max(1, Int((Double(nfft) / Double(lagMax)).rounded(.up))), bHi = min(power.count - 1, Int(Double(nfft) / Double(lagMin)))
        guard bHi > bLo + 8 else { return empty(flat: false, used: used) }
        let band = Array(power[bLo...bHi])
        let logBand = band.map { log(max($0, 1e-30)) }
        let half = max(8, band.count / 80)
        var baseline = [Double](repeating: 0, count: band.count)
        for i in band.indices { baseline[i] = median(Array(logBand[max(0, i - half)...min(band.count - 1, i + half)])) }
        let residual = zip(logBand, baseline).map { $0 - $1 }
        let (_, mad) = robust(residual)
        let scale = max(1.4826 * mad, 1 / Double(used).squareRoot())
        func z(_ i: Int) -> Double { residual[i] / scale }
        func isLocalMaximum(_ i: Int) -> Bool {
            let left = i > 0 ? band[i - 1] : -.infinity, right = i + 1 < band.count ? band[i + 1] : -.infinity
            return band[i] > left && band[i] >= right
        }
        func period(_ i: Int) -> Double { Double(nfft) / Double(i + bLo) }
        func peak(_ i: Int, confirmed: Bool, fundamental: Bool) -> PeriodicityPeak {
            let p = period(i)
            return PeriodicityPeak(period: p, lag: Int(p.rounded()), samples: p * columnSamples, milliseconds: p * columnSeconds * 1000, power: band[i], z: z(i),
                                   confirmed: confirmed, fundamental: fundamental)
        }
        func tolerance(_ b: Double) -> Int { max(2, Int((0.01 * b).rounded())) }
        /// A local maximum with z ≥ `atLeast` within the tolerance of bin `b`.
        func line(near b: Double, atLeast: Double) -> Bool {
            let tolerance = tolerance(b)
            for candidate in (Int(b.rounded()) - tolerance)...(Int(b.rounded()) + tolerance) {
                let i = candidate - bLo
                if i >= 0, i < band.count, isLocalMaximum(i), z(i) >= atLeast { return true }
            }
            return false
        }
        var candidates: [(i: Int, confirmed: Bool)] = []
        for i in band.indices where isLocalMaximum(i) && z(i) >= harmonicZ {
            let b = Double(i + bLo)
            var confirmed = z(i) >= peakZ && 2 * b <= Double(bHi) && line(near: 2 * b, atLeast: harmonicZ)
            if confirmed && 3 * b <= Double(bHi) { confirmed = line(near: 3 * b, atLeast: harmonicZ) }
            candidates.append((i, confirmed))
        }
        let confirmedBins = candidates.filter(\.confirmed).map { $0.i + bLo }.sorted()
        /// A confirmed line at a lower bin of which `b` is an integer multiple, within the tolerance.
        func isHarmonic(_ b: Int) -> Bool {
            for lower in confirmedBins where Double(b) / Double(lower) >= 1.9 {
                let m = (Double(b) / Double(lower)).rounded()
                if abs(Double(b) - m * Double(lower)) <= Double(tolerance(Double(b))) { return true }
            }
            return false
        }
        var peaks: [PeriodicityPeak] = []
        for (i, confirmed) in candidates {
            peaks.append(peak(i, confirmed: confirmed, fundamental: confirmed && !isHarmonic(i + bLo)))
        }
        let steps = peaks.filter(\.fundamental).sorted { $0.period < $1.period }
        var curve = [Double](repeating: 0, count: curvePoints)
        for k in 0..<curvePoints {
            let i = min(band.count - 1, Int(Double(k) * Double(band.count - 1) / Double(curvePoints - 1)))
            curve[k] = z(i)
        }
        let probed = probes.map { lag -> PeriodicityProbe in
            guard lag > 0 else { return PeriodicityProbe(lag: lag, z: 0) }
            let b = Double(nfft) / lag
            let tolerance = tolerance(b)
            var best = -Double.infinity
            for candidate in (Int(b.rounded()) - tolerance)...(Int(b.rounded()) + tolerance) {
                let i = candidate - bLo
                if i >= 0, i < band.count { best = max(best, z(i)) }
            }
            return PeriodicityProbe(lag: lag, z: best.isFinite ? best : 0)
        }
        return Periodicity(lagMin: lagMin, lagMax: lagMax, columnSeconds: columnSeconds, nfft: nfft, rowsUsed: used, flat: false, peaks: peaks, steps: steps,
                           dominant: steps.max { $0.z < $1.z }, probes: probed, curve: curve)
    }

    /// A row standardized and freed of its centred moving average; nil when it has no spread.
    static func prepared(_ row: [Float], window: Int) -> [Double]? {
        let n = row.count
        guard n > 1 else { return nil }
        var mean = 0.0
        for x in row { mean += Double(x) }
        mean /= Double(n)
        var variance = 0.0
        for x in row { variance += (Double(x) - mean) * (Double(x) - mean) }
        variance /= Double(n)
        let sd = variance.squareRoot()
        // A row whose spread is under one part in ten thousand of its level is flat: a stationary tone's picture is constant along
        // time, and what remains is the arithmetic's own ripple, which the first run read as steps of 53 and 87 ms (N1, 2026-11-08).
        guard sd > 1e-4 * max(abs(mean), 1e-30) else { return nil }
        let x = row.map { (Double($0) - mean) / sd }
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + x[i] }
        let half = window / 2
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - half), hi = min(n - 1, i + half)
            out[i] = x[i] - (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }
        return out
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The median and the median absolute deviation.
    static func robust(_ values: [Double]) -> (median: Double, mad: Double) {
        guard !values.isEmpty else { return (0, 0) }
        let m = median(values)
        return (m, median(values.map { abs($0 - m) }))
    }
}
