//
//  AnalysisSignal.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The carrier's canonical input: one channel of Double samples at the profile's rate, made
//        from any clip; and the way back to a clip for writing.
//  PIN:  Mixdown (the channels' mean), then AudioConverting's resampler when the clip's rate is
//        not the profile's; identity otherwise, so a cut of a clip at the profile's rate holds
//        exactly its source's samples and its interior frames equal the source's. No mean is
//        removed: a DC offset would shift source and cut alike, and the picture drops the DC bin.
//        A clip over the duration cap is refused here, before any memory is spent on it.
//

import Foundation
import VeilGardeCore

public struct AnalysisSignal: Sendable, Equatable {
    public let profile: SpectrogramProfile
    public var samples: [Double]

    public init(profile: SpectrogramProfile, samples: [Double]) {
        self.profile = profile
        self.samples = samples
    }

    public init(_ clip: AudioClip, profile: SpectrogramProfile) throws {
        guard clip.seconds <= SpectrogramProfile.maximumSeconds else {
            throw VeilGardeFailure.usage(String(format: "the clip is %.0f s long; the carrier takes up to %.0f s", clip.seconds, SpectrogramProfile.maximumSeconds),
                                         hint: "cut a window with `veilgarde audio export --start --duration`")
        }
        let resampled = try AudioConverting.resampled(clip.mono, from: clip.sampleRate, to: profile.sampleRate)
        self.profile = profile
        self.samples = resampled.map(Double.init)
    }

    public var frames: Int { profile.frameCount(samples: samples.count) }
    public var seconds: Double { Double(samples.count) / profile.sampleRate }

    public var rmsDBFS: Double {
        var sum = 0.0
        for x in samples { sum += x * x }
        guard !samples.isEmpty, sum > 0 else { return -.infinity }
        return 10 * log10(sum / Double(samples.count))
    }

    /// A mono clip at the profile's rate.
    public func clip() -> AudioClip { AudioClip(sampleRate: profile.sampleRate, mono: samples.map(Float.init)) }
}
