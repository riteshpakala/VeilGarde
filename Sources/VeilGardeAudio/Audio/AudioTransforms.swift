//
//  AudioTransforms.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What the acceptance does to a clip before matching it again: a cut (the crop's analog), a
//        gain change, a requantization to 16 bits, and white noise at a signal-to-noise ratio.
//        Speed changes and the AAC re-encode live in AudioConverting, behind door two.
//  PIN:  A cut is clamped to the clip. The requantization rounds each sample to the nearest
//        1/32767 with no dither, as a 16-bit WAV would store it. The noise is Gaussian by Box–Muller
//        from SplitMix64, one stream per channel (seed ^ channel + 1), scaled so the mixdown's
//        RMS over the noise's is the ratio asked for.
//

import Foundation
import VeilGardeCore

public enum AudioTransforms {
    /// `length` samples of `clip` from `startSample`, both clamped to the clip.
    public static func cut(_ clip: AudioClip, startSample: Int, length: Int) -> AudioClip {
        let start = max(0, min(startSample, clip.frames))
        let end = max(start, min(clip.frames, start + max(0, length)))
        return AudioClip(validated: clip.sampleRate, channels: clip.channels.map { Array($0[start..<end]) })
    }

    public static func gained(_ clip: AudioClip, dB: Double) -> AudioClip {
        let gain = Float(pow(10, dB / 20))
        return AudioClip(validated: clip.sampleRate, channels: clip.channels.map { $0.map { $0 * gain } })
    }

    /// Every sample on the 16-bit grid, clamped to full scale.
    public static func requantized16Bit(_ clip: AudioClip) -> AudioClip {
        AudioClip(validated: clip.sampleRate, channels: clip.channels.map { channel in
            channel.map { x in Float(max(-32768, min(32767, (Double(x) * 32767).rounded())) / 32767) }
        })
    }

    /// `clip` plus white Gaussian noise at `snrDB` below the mixdown's RMS.
    public static func withWhiteNoise(_ clip: AudioClip, snrDB: Double, seed: UInt64) -> AudioClip {
        let level = clip.rmsDBFS
        guard level.isFinite else { return clip }
        let noiseRMS = pow(10, (level - snrDB) / 20)
        var channels: [[Float]] = []
        for (c, channel) in clip.channels.enumerated() {
            var rng = SplitMix64(seed: seed ^ UInt64(c + 1))
            channels.append(channel.map { Float(Double($0) + noiseRMS * gaussian(&rng)) })
        }
        return AudioClip(validated: clip.sampleRate, channels: channels)
    }

    /// A standard normal draw by Box–Muller.
    public static func gaussian(_ rng: inout SplitMix64) -> Double {
        let u1 = max(rng.unit(), 1e-300), u2 = rng.unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}
