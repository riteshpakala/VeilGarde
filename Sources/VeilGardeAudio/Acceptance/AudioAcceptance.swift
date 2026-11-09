//
//  AudioAcceptance.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Whether v1 holds on sound, measured as the image lane measures it: for each admitted clip,
//        a self-match, a half-duration cut at a random sample offset (its match and the offset it
//        recovers), an AAC re-encode, a cross match of the cut against the next clip's signature
//        (the false matches), and on every fourth clip the cut's speed changed by 0.9× and 0.75×
//        (where v1 is expected to break). Then the kill criterion, stated before the run. Beside
//        it, measured and not gated: a tile-aligned cut, a gain change, 16-bit requantization,
//        white noise, both round trips, and each clip's fragility statistics.
//  PIN:  The acceptance, fixed before the run (ledger decision-142): self-match 100%; the cut
//        matches (score ≥ 0.75, ≥ 256 bits) with its offset within one tile in at least 60% of
//        clips; the median AAC score is at least 0.75; some threshold reaches ≥ 80% cut recall at
//        ≤ 5% cross false matches. Failing any kills v1 on audio. The AAC rate is the profile's, or
//        the highest the encoder offers below it at the clip's rate, recorded per clip. The fallbacks, named now: a
//        sub-hop phase search at quarter-hop sample offsets; the hop halved; the floor at −80 dB if
//        the false-match rule kills; the image lane's own. The cut and the speed changes use the
//        time-phase search; the re-encode, realigned by its measured lag, the gain, the
//        requantization and the noise are matched at phase 0, as the JPEG is. With cutSubHop 4 the
//        cut is also tried with its first quarter, half and three quarters of a hop dropped, the
//        best score kept, and the cross match gets the same four chances (experiment B). Admission: the
//        profile's minimum duration, the duration cap and an RMS of at least −40 dBFS. Seeded by
//        SplitMix64: per clip the cut's start, then the noise seed. Nothing is written but the
//        report, each clip's row as it is measured, and the codec's transient file.
//

import Foundation
import VeilGardeCore
import VeilWatermark

public struct AudioAcceptanceSettings: Codable, Sendable, Equatable {
    public var seed: UInt64 = 0
    public var profile: String = SpectrogramProfile.music.name
    public var cutFraction = 0.5
    public var speeds: [Double] = [0.9, 0.75]
    /// The speed changes are measured on every n-th clip.
    public var speedEvery = 4
    public var gainDB: Double = -6
    public var noiseSNRDB: Double = 30
    public var phases: [Int] = MatchOptions.default.phases
    public var minimumBits = MatchOptions.default.minimumBits
    public var threshold = MatchOptions.default.threshold
    /// Tracks are cut into segments this long before sampling; 0 keeps whole files.
    public var segmentSeconds: Double = 10
    /// Fractions of a hop the cut is also tried at, the best kept: 1 is the plain search, 4 tries 0, ¼, ½ and ¾ (experiment B).
    public var cutSubHop = 1

    public init() {}

    public var spectrogramProfile: SpectrogramProfile { SpectrogramProfile.named(profile) ?? .music }
    var options: MatchOptions { MatchOptions(phases: phases, minimumBits: minimumBits, threshold: threshold) }
    var phaseZero: MatchOptions { MatchOptions(phases: [0], minimumBits: minimumBits, threshold: threshold) }
}

public struct AudioAcceptanceInput: Sendable {
    public var path: String
    public var segment: Int
    public var kind: String
    public var clip: AudioClip

    public init(path: String, segment: Int, kind: String, clip: AudioClip) {
        self.path = path
        self.segment = segment
        self.kind = kind
        self.clip = clip
    }
}

public struct AudioAcceptanceClip: Codable, Sendable {
    public struct Cut: Codable, Sendable {
        public var startSample: Int
        public var length: Int
        public var expectedColumn: Int
        public var seconds: Double
    }

    public struct Reencode: Codable, Sendable {
        public var match: MatchResult
        public var lagSamples: Int
        public var lengthDelta: Int
        /// The profile's rate, the one the encoder offered and was set to, and the stream's measured rate.
        public var requestedKilobitsPerSecond: Int
        public var usedKilobitsPerSecond: Int
        public var kilobitsPerSecond: Double
    }

    public var path: String
    public var segment: Int
    public var kind: String
    public var nativeRate: Double
    public var channels: Int
    public var seconds: Double
    public var frames: Int
    public var rmsDBFS: Double
    public var signedBits: Int
    public var balance: [Double]
    public var floorShare: Double
    public var frMean: Double
    public var frSpread: Double
    public var selfMatch: MatchResult
    public var cut: Cut
    public var cutMatch: MatchResult
    /// Which fraction of a hop won the cut's search: 0 of cutSubHop when the plain cut did.
    public var cutSubHopOffset: Int
    /// The recovered column's distance from the truth, in tiles (the larger of time and frequency).
    public var cutOffsetError: Double
    public var alignedCutMatch: MatchResult
    public var reencode: Reencode
    public var cross: MatchResult
    public var speed: [String: MatchResult]
    public var gain: MatchResult
    public var pcm16: MatchResult
    public var noise: MatchResult
    public var roundTripExact: AudioRoundTripMetrics
    public var roundTripImage: AudioRoundTripMetrics
    public var elapsed: Double
}

public struct AudioAcceptanceSummary: Codable, Sendable {
    public var clips: Int
    public var selfMatchRate: Double
    public var cutMatchRate: Double
    public var reencodeMedianScore: Double
    public var crossFalseMatchRate: Double
    public var crossMedianScore: Double
    /// The best threshold for cut recall ≥ 80%, and its false-match rate.
    public var operatingThreshold: Double?
    public var operatingRecall: Double?
    public var operatingFalseMatchRate: Double?
    public var bitBalance: [Double]
    public var speedMatchRate: [String: Double]
    public var alignedCutMatchRate: Double
    public var gainMedianScore: Double
    public var pcm16MedianScore: Double
    public var noiseMedianScore: Double
    public var reencodeLagZeroRate: Double
    public var offsetYNonZero: Int
    public var degenerateClips: Int
    public var exactSNRMedianDB: Double
    public var imageSNRMedianDB: Double
    public var killed: Bool
    public var reasons: [String]
}

public struct AudioAcceptanceReport: Codable, Sendable {
    public var date: Date
    public var settings: AudioAcceptanceSettings
    public var profile: SpectrogramProfile.Record
    public var summary: AudioAcceptanceSummary
    public var clips: [AudioAcceptanceClip]
}

public enum AudioAcceptance {
    /// `count` music-like clips, seeds 1…count, 12 s at the profile's rate.
    public static func synthetic(count: Int, profile: SpectrogramProfile) -> [AudioAcceptanceInput] {
        (1...max(1, count)).map { seed in
            AudioAcceptanceInput(path: "synthetic:musicLike:\(seed)", segment: 0, kind: "synthetic",
                                 clip: SyntheticClips.musicLike(seed: UInt64(seed), seconds: 12, sampleRate: profile.sampleRate))
        }
    }

    public static func run(_ inputs: [AudioAcceptanceInput], settings: AudioAcceptanceSettings = AudioAcceptanceSettings(),
                           note: (String) -> Void = { _ in }, measured: (AudioAcceptanceClip) -> Void = { _ in }) throws -> AudioAcceptanceReport {
        var rng = SplitMix64(seed: settings.seed)
        let profile = settings.spectrogramProfile
        let options = settings.options, phaseZero = settings.phaseZero
        // Pass 1: every signature (the cross matches need the next clip's).
        var admitted: [(input: AudioAcceptanceInput, image: SpectrogramImage, signature: WatermarkSignature, grid: FragilityGrid)] = []
        for input in inputs {
            let clip = input.clip
            let label = input.kind == "synthetic" ? input.path : "\(URL(fileURLWithPath: input.path).lastPathComponent)#\(input.segment)"
            if clip.seconds < profile.minimumSeconds {
                note(String(format: "accept: skipped %@: %.1f s, under the %@ profile's %.0f s", label, clip.seconds, profile.name, profile.minimumSeconds)); continue
            }
            if clip.seconds > SpectrogramProfile.maximumSeconds { note(String(format: "accept: skipped %@: %.0f s, over the cap", label, clip.seconds)); continue }
            let level = clip.rmsDBFS
            if level < SpectrogramProfile.minimumRMSDBFS { note(String(format: "accept: skipped %@: %.1f dBFS, under −40", label, level)); continue }
            let image = try AudioWatermark.picture(clip, profile: profile)
            // One fragility read: the signature is built from it exactly as Watermark.sign builds it (AudioWatermarkTests).
            let grid = try AudioWatermark.fragility(image)
            let signature = WatermarkSignature(grid: TileCodeGrid(grid))
            admitted.append((input, image, signature, grid))
            if admitted.count % 10 == 0 { note("accept: signed \(admitted.count) of \(inputs.count)") }
        }
        note("accept: signed \(admitted.count) clips (\(inputs.count - admitted.count) skipped); matching")
        var rows: [AudioAcceptanceClip] = []
        for (i, entry) in admitted.enumerated() {
            let started = Date()
            let clip = entry.input.clip, image = entry.image, signature = entry.signature
            let selfMatch = try AudioWatermark.match(image, against: signature, options: phaseZero).result
            // A cut of half the duration, at a random native-sample offset; with cutSubHop over 1, also with its first fractions
            // of a hop dropped, the best score kept (experiment B), and the cross match gets the same chances.
            let cutLength = max(1, Int(Double(clip.frames) * settings.cutFraction))
            let start = rng.index(max(1, clip.frames - cutLength + 1))
            let cutClip = AudioTransforms.cut(clip, startSample: start, length: cutLength)
            let subHop = max(1, settings.cutSubHop)
            var cutMatch = MatchResult.none, cutCodesTried: [[(px: Int, py: Int, codes: TileCodeGrid)]] = [], expected = 0, cutSubHopOffset = 0
            for q in 0..<subHop {
                let delta = Int((Double(q) / Double(subHop) * Double(profile.hop) * clip.sampleRate / profile.sampleRate).rounded())
                let shifted = q == 0 ? cutClip : AudioTransforms.cut(cutClip, startSample: delta, length: cutClip.frames - delta)
                let codes = try AudioWatermark.phaseCodes(try AudioWatermark.picture(shifted, profile: profile), phases: settings.phases)
                cutCodesTried.append(codes)
                let m = Watermark.match(codes: codes, against: signature, options: options)
                if q == 0 || m.score > cutMatch.score {
                    cutMatch = m
                    cutSubHopOffset = q
                    expected = AudioWatermark.expectedColumn(startSample: start + delta, nativeRate: clip.sampleRate, profile: profile)
                }
            }
            let cutError = max(Double(abs(cutMatch.pixelX - expected)) / Double(WarpConstants.tileSize), Double(abs(cutMatch.offsetY)))
            // The same cut moved to the nearest tile column boundary, matched at phase 0: the picture-equality claim alone.
            let tileNative = Double(profile.hop * WarpConstants.tileSize) * clip.sampleRate / profile.sampleRate
            let alignedStart = max(0, min(Int((Double(start) / tileNative).rounded() * tileNative), clip.frames - cutLength))
            let alignedCut = AudioTransforms.cut(clip, startSample: alignedStart, length: cutLength)
            let alignedMatch = try AudioWatermark.match(try AudioWatermark.picture(alignedCut, profile: profile), against: signature, options: phaseZero).result
            // The re-encode, realigned by its measured lag, matched at phase 0 like the JPEG.
            let aac = try AudioConverting.aacRoundTrip(clip, kilobitsPerSecond: profile.aacKilobitsPerSecond)
            let lag = SignalAlignment.lag(of: aac.clip.mono, against: clip.mono)
            let realigned = AudioClip(sampleRate: clip.sampleRate, mono: SignalAlignment.aligned(aac.clip.mono, by: lag, length: clip.frames))
            let reencodeMatch = try AudioWatermark.match(try AudioWatermark.picture(realigned, profile: profile), against: signature, options: phaseZero).result
            let other = admitted[(i + 1) % admitted.count].signature
            var cross = MatchResult.none
            for (q, codes) in cutCodesTried.enumerated() {
                let m = Watermark.match(codes: codes, against: other, options: options)
                if q == 0 || m.score > cross.score { cross = m }
            }
            var speed: [String: MatchResult] = [:]
            for factor in settings.speeds where i % max(1, settings.speedEvery) == 0 {
                let changed = try AudioConverting.speedChanged(cutClip, by: factor)
                speed[String(format: "%.2f", factor)] = Watermark.match(codes: try AudioWatermark.phaseCodes(try AudioWatermark.picture(changed, profile: profile), phases: settings.phases),
                                                                       against: signature, options: options)
            }
            let gain = try AudioWatermark.match(try AudioWatermark.picture(AudioTransforms.gained(clip, dB: settings.gainDB), profile: profile), against: signature, options: phaseZero).result
            let pcm16 = try AudioWatermark.match(try AudioWatermark.picture(AudioTransforms.requantized16Bit(clip), profile: profile), against: signature, options: phaseZero).result
            let noiseSeed = rng.next()
            let noise = try AudioWatermark.match(try AudioWatermark.picture(AudioTransforms.withWhiteNoise(clip, snrDB: settings.noiseSNRDB, seed: noiseSeed), profile: profile),
                                                 against: signature, options: phaseZero).result
            let signal = try AnalysisSignal(clip, profile: profile)
            let exact = AudioRoundTrip.exact(signal).metrics
            let viaImage = AudioRoundTrip.throughImage(signal).metrics
            var frMean = 0.0
            for v in entry.grid.values { frMean += Double(v) }
            frMean /= Double(max(1, entry.grid.values.count))
            var frVariance = 0.0
            for v in entry.grid.values { frVariance += (Double(v) - frMean) * (Double(v) - frMean) }
            frVariance /= Double(max(1, entry.grid.values.count))
            let codes = signature.tileCodes
            rows.append(AudioAcceptanceClip(
                path: entry.input.path, segment: entry.input.segment, kind: entry.input.kind, nativeRate: clip.sampleRate, channels: clip.channelCount,
                seconds: clip.seconds, frames: image.width, rmsDBFS: clip.rmsDBFS, signedBits: signature.measuredBits, balance: codes.balance,
                floorShare: image.floorShare, frMean: frMean, frSpread: frVariance.squareRoot(), selfMatch: selfMatch,
                cut: .init(startSample: start, length: cutLength, expectedColumn: expected, seconds: Double(start) / clip.sampleRate),
                cutMatch: cutMatch, cutSubHopOffset: cutSubHopOffset, cutOffsetError: cutError, alignedCutMatch: alignedMatch,
                reencode: .init(match: reencodeMatch, lagSamples: lag, lengthDelta: aac.lengthDelta, requestedKilobitsPerSecond: aac.requestedKilobitsPerSecond,
                                usedKilobitsPerSecond: aac.usedKilobitsPerSecond, kilobitsPerSecond: aac.kilobitsPerSecond),
                cross: cross, speed: speed, gain: gain, pcm16: pcm16, noise: noise, roundTripExact: exact, roundTripImage: viaImage,
                elapsed: Date().timeIntervalSince(started)))
            measured(rows[rows.count - 1])
            let label = entry.input.kind == "synthetic" ? entry.input.path : "\(URL(fileURLWithPath: entry.input.path).lastPathComponent)#\(entry.input.segment)"
            note(String(format: "accept %d/%d %@: self %.3f, cut %.3f (%d bits, off by %.2f tiles), aac %.3f (lag %d), cross %.3f, %.0fs", i + 1, admitted.count, label,
                        selfMatch.score, cutMatch.score, cutMatch.bitsCompared, cutError, reencodeMatch.score, lag, cross.score, rows[rows.count - 1].elapsed))
        }
        return AudioAcceptanceReport(date: Date(), settings: settings, profile: profile.record, summary: summarize(rows, settings: settings), clips: rows)
    }

    public static func summarize(_ rows: [AudioAcceptanceClip], settings: AudioAcceptanceSettings) -> AudioAcceptanceSummary {
        let n = Double(max(1, rows.count))
        func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
        let selfOK = rows.filter { $0.selfMatch.matched && $0.selfMatch.offsetX == 0 && $0.selfMatch.offsetY == 0 && $0.selfMatch.score == 1 }.count
        let cutOK = rows.filter { $0.cutMatch.matched && $0.cutOffsetError <= 1 }.count
        let crossFalse = rows.filter { $0.cross.matched }.count
        // The operating point: the threshold with cut recall ≥ 80% and the fewest false matches.
        var op: (t: Double, recall: Double, fpr: Double)? = nil
        for k in 50...100 {
            let t = Double(k) / 100
            let recall = Double(rows.filter { $0.cutMatch.score >= t && $0.cutMatch.bitsCompared >= settings.minimumBits && $0.cutOffsetError <= 1 }.count) / n
            let fpr = Double(rows.filter { $0.cross.score >= t && $0.cross.bitsCompared >= settings.minimumBits }.count) / n
            if recall >= 0.80, op == nil || fpr < op!.fpr || (fpr == op!.fpr && t > op!.t) { op = (t, recall, fpr) }
        }
        var balance = [Double](repeating: 0, count: 4)
        for k in 0..<4 { balance[k] = median(rows.map { $0.balance[k] }.filter(\.isFinite)) }
        var speedRate: [String: Double] = [:]
        for key in Set(rows.flatMap { $0.speed.keys }) {
            let measured = rows.filter { $0.speed[key] != nil }
            speedRate[key] = Double(measured.filter { $0.speed[key]?.matched == true }.count) / Double(max(1, measured.count))
        }
        let cutRate = Double(cutOK) / n, reencodeMedian = median(rows.map(\.reencode.match.score))
        var reasons: [String] = []
        if cutRate < 0.60 { reasons.append(String(format: "the cut matched with its offset in %.0f%% of clips, under 60%%", cutRate * 100)) }
        if reencodeMedian < 0.75 { reasons.append(String(format: "the median AAC re-encode score is %.3f, under 0.75", reencodeMedian)) }
        if let op, op.fpr > 0.05 { reasons.append(String(format: "at 80%% cut recall the fewest false matches are %.1f%%, over 5%%", op.fpr * 100)) }
        if op == nil { reasons.append("no threshold reaches 80% cut recall") }
        let degenerate = rows.filter { $0.floorShare > 0.9 || $0.balance.allSatisfy { $0 < 0.05 } }.count
        return AudioAcceptanceSummary(
            clips: rows.count, selfMatchRate: Double(selfOK) / n, cutMatchRate: cutRate, reencodeMedianScore: reencodeMedian,
            crossFalseMatchRate: Double(crossFalse) / n, crossMedianScore: median(rows.map(\.cross.score)),
            operatingThreshold: op?.t, operatingRecall: op?.recall, operatingFalseMatchRate: op?.fpr, bitBalance: balance, speedMatchRate: speedRate,
            alignedCutMatchRate: Double(rows.filter(\.alignedCutMatch.matched).count) / n,
            gainMedianScore: median(rows.map(\.gain.score)), pcm16MedianScore: median(rows.map(\.pcm16.score)), noiseMedianScore: median(rows.map(\.noise.score)),
            reencodeLagZeroRate: Double(rows.filter { $0.reencode.lagSamples == 0 }.count) / n,
            offsetYNonZero: rows.filter { $0.cutMatch.matched && $0.cutMatch.offsetY != 0 }.count, degenerateClips: degenerate,
            exactSNRMedianDB: median(rows.map(\.roundTripExact.snrDB)), imageSNRMedianDB: median(rows.map(\.roundTripImage.snrDB)),
            killed: !reasons.isEmpty, reasons: reasons)
    }
}
