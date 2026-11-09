//
//  AudioWatermark.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The thin door from a clip to the watermark: its picture, its signature by Watermark.sign,
//        its fragility grid, and a match of a clip against a signature with the grid phases read
//        along time only; the match carries the offset in seconds.
//  PIN:  Nothing in VeilWatermark changes or is bypassed: the signature is Watermark.sign of the
//        picture's bitmap, a vw1 no different from an image's. Matching reads
//        NativePlane.fragility(originX: px, originY: 0) for px in the phases, 0, 8, 16 and 24 by
//        default, four grid reads instead of sixteen, since a cut keeps every frequency row; the
//        thresholds are the watermark's own, 0.75 over 256 bits. A clip is signed at any length
//        with one full tile column, as an image is; only the acceptance admits by duration. The
//        profile of a signature is read off its tile rows, 32 for music and 16 for speech.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens
import VeilWatermark

public struct AudioMatchResult: Codable, Sendable, Equatable {
    /// The watermark's own result, offsets in tiles and the phase in pixels.
    public var result: MatchResult
    public var profile: String
    /// The probe picture's width in frames.
    public var frames: Int
    public var hop: Int
    public var sampleRate: Double

    public init(result: MatchResult, profile: SpectrogramProfile, frames: Int) {
        self.result = result
        self.profile = profile.name
        self.frames = frames
        self.hop = profile.hop
        self.sampleRate = profile.sampleRate
    }

    public var matched: Bool { result.matched }
    /// The signed picture's column the probe's first frame stands on.
    public var column: Int { result.pixelX }
    /// That column in seconds of the signed clip.
    public var seconds: Double { Double(result.pixelX) * Double(hop) / sampleRate }
    /// The frequency offset in tile rows; 0 for a true match.
    public var frequencyRows: Int { result.offsetY }

    enum CodingKeys: String, CodingKey { case result, profile, frames, hop, sampleRate, column, seconds, frequencyRows }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        result = try c.decode(MatchResult.self, forKey: .result)
        profile = try c.decode(String.self, forKey: .profile)
        frames = try c.decode(Int.self, forKey: .frames)
        hop = try c.decode(Int.self, forKey: .hop)
        sampleRate = try c.decode(Double.self, forKey: .sampleRate)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(result, forKey: .result)
        try c.encode(profile, forKey: .profile)
        try c.encode(frames, forKey: .frames)
        try c.encode(hop, forKey: .hop)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(column, forKey: .column)
        try c.encode(seconds, forKey: .seconds)
        try c.encode(frequencyRows, forKey: .frequencyRows)
    }
}

public enum AudioWatermark {
    /// The picture of `clip` under `profile`.
    public static func picture(_ clip: AudioClip, profile: SpectrogramProfile) throws -> SpectrogramImage {
        SpectrogramImage(Spectrogram(try AnalysisSignal(clip, profile: profile)))
    }

    /// `clip`'s signature: the watermark's own, read off its picture.
    public static func sign(_ clip: AudioClip, profile: SpectrogramProfile) throws -> WatermarkSignature {
        try sign(try picture(clip, profile: profile))
    }

    public static func sign(_ image: SpectrogramImage) throws -> WatermarkSignature {
        try Watermark.sign(try image.cgImage)
    }

    /// Every full tile's fragility rate of the picture, at phase (0, 0).
    public static func fragility(_ image: SpectrogramImage) throws -> FragilityGrid {
        defer { LensRuntime.releaseMemory() }
        return try NativePlane(try image.cgImage).fragility()
    }

    public static func fragility(_ clip: AudioClip, profile: SpectrogramProfile) throws -> FragilityGrid {
        try fragility(try picture(clip, profile: profile))
    }

    /// The picture's tile codes at each time phase, the frequency phase 0.
    public static func phaseCodes(_ image: SpectrogramImage, phases: [Int] = MatchOptions.default.phases) throws -> [(px: Int, py: Int, codes: TileCodeGrid)] {
        defer { LensRuntime.releaseMemory() }
        let plane = try NativePlane(try image.cgImage)
        return phases.map { px in (px, 0, TileCodeGrid(plane.fragility(originX: px, originY: 0))) }
    }

    /// Where `clip` sits on `signature`; the profile is the signature's own unless given.
    public static func match(_ clip: AudioClip, against signature: WatermarkSignature, profile: SpectrogramProfile? = nil,
                             options: MatchOptions = .default) throws -> AudioMatchResult {
        let p = try profile ?? self.profile(of: signature)
        return try match(try picture(clip, profile: p), against: signature, options: options)
    }

    public static func match(_ image: SpectrogramImage, against signature: WatermarkSignature, options: MatchOptions = .default) throws -> AudioMatchResult {
        let result = Watermark.match(codes: try phaseCodes(image, phases: options.phases), against: signature, options: options)
        return AudioMatchResult(result: result, profile: image.profile, frames: image.width)
    }

    /// The profile a signature was made under, from its tile rows.
    public static func profile(of signature: WatermarkSignature) throws -> SpectrogramProfile {
        guard let p = SpectrogramProfile.inferred(rows: signature.rows) else {
            throw VeilGardeFailure.data("a signature of \(signature.rows) tile rows fits no audio profile", hint: "music pictures have 32 tile rows, speech 16")
        }
        return p
    }

    /// The signed picture's column a cut starting at `startSample` of a clip at `nativeRate` begins on.
    public static func expectedColumn(startSample: Int, nativeRate: Double, profile: SpectrogramProfile) -> Int {
        Int((Double(startSample) / nativeRate * profile.sampleRate / Double(profile.hop)).rounded())
    }
}
