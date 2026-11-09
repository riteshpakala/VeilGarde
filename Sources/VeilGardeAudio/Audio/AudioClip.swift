//
//  AudioClip.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A decoded clip as the carrier holds it: its native sample rate and its channels as Float
//        samples, deinterleaved; its length, its peak and its level; and the mixdown every analysis
//        starts from.
//  PIN:  The mixdown is the per-sample mean over the channels, accumulated in Double and rounded to
//        Float once. Nothing here resamples: a clip keeps its native rate until an analysis signal
//        is made from it (AnalysisSignal), so every transform the acceptance applies acts on the
//        clip as a platform would act on the file.
//

import Foundation
import VeilGardeCore

public struct AudioClip: Sendable, Equatable {
    public var sampleRate: Double
    /// Deinterleaved, one array per channel, all the same length.
    public var channels: [[Float]]

    public init(sampleRate: Double, channels: [[Float]]) throws {
        guard sampleRate > 0 else { throw VeilGardeFailure.data("a clip needs a positive sample rate, not \(sampleRate)") }
        guard let first = channels.first else { throw VeilGardeFailure.data("a clip needs at least one channel") }
        guard channels.allSatisfy({ $0.count == first.count }) else { throw VeilGardeFailure.data("a clip's channels must be equally long") }
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public init(sampleRate: Double, mono: [Float]) {
        self.sampleRate = sampleRate
        self.channels = [mono]
    }

    /// For callers that already hold equal-length channels of a valid clip.
    init(validated sampleRate: Double, channels: [[Float]]) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var channelCount: Int { channels.count }
    public var frames: Int { channels.first?.count ?? 0 }
    public var seconds: Double { Double(frames) / sampleRate }

    /// The mixdown: the per-sample mean over the channels, in Double, rounded once.
    public var mono: [Float] {
        if channels.count == 1 { return channels[0] }
        let n = frames
        var out = [Float](repeating: 0, count: n)
        let scale = 1.0 / Double(channels.count)
        for i in 0..<n {
            var sum = 0.0
            for channel in channels { sum += Double(channel[i]) }
            out[i] = Float(sum * scale)
        }
        return out
    }

    /// The largest absolute sample over every channel.
    public var peak: Float { channels.reduce(0) { most, channel in channel.reduce(most) { max($0, abs($1)) } } }

    /// The mixdown's level in dBFS (an RMS of 1 is 0 dBFS); −infinity for silence.
    public var rmsDBFS: Double { AudioClip.rmsDBFS(mono) }

    public static func rmsDBFS(_ samples: [Float]) -> Double {
        var sum = 0.0
        for x in samples { sum += Double(x) * Double(x) }
        guard !samples.isEmpty, sum > 0 else { return -.infinity }
        return 10 * log10(sum / Double(samples.count))
    }
}
