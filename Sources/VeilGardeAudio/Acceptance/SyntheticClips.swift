//
//  SyntheticClips.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Seeded signals for the tests, the examples and `audio accept --synthetic`: a music-like
//        mix of harmonic voices with notes, attacks and decays, one exponential chirp, Gaussian
//        bursts and a quiet noise bed; white noise; a tone; silence; a click train. And a hash of a clip's 16-bit
//        samples, so a drift in the generator is told from a drift in the carrier.
//  PIN:  Every draw comes from SplitMix64(seed) in one fixed order; sin, exp and pow are the
//        platform's, so a pin holds on one machine and says so. The music-like clip is six voices
//        of five partials at 1/k^1.2 over 12-TET notes of 0.25 to 1 s with 5 ms attacks and a 0.4 s
//        decay, a 200 → 4000 Hz chirp at −24 dBFS, bursts of 20–80 ms at −20 dBFS about every 1.5 s
//        and a −60 dBFS Gaussian bed, the whole peak-normalised.
//

import Foundation
import VeilGardeCore

public enum SyntheticClips {
    public enum Kind: String, Codable, Sendable, CaseIterable { case musicLike, whiteNoise, tone, silence, clicks }

    public static func make(_ kind: Kind, seed: UInt64, seconds: Double = 12, sampleRate: Double = 44_100, peak: Double = 0.5) -> AudioClip {
        switch kind {
        case .musicLike: return musicLike(seed: seed, seconds: seconds, sampleRate: sampleRate, peak: peak)
        case .whiteNoise: return whiteNoise(seed: seed, rmsDBFS: -20, seconds: seconds, sampleRate: sampleRate)
        case .tone: return tone(frequency: 440, amplitude: peak, seconds: seconds, sampleRate: sampleRate)
        case .silence: return silence(seconds: seconds, sampleRate: sampleRate)
        case .clicks: return clicks(seed: seed, seconds: seconds, sampleRate: sampleRate)
        }
    }

    public static func musicLike(seed: UInt64, seconds: Double = 12, sampleRate: Double = 44_100, peak: Double = 0.5) -> AudioClip {
        let n = Int(seconds * sampleRate)
        var out = [Double](repeating: 0, count: n)
        var rng = SplitMix64(seed: seed)
        let durations = [0.25, 0.5, 0.75, 1.0]
        let attack = max(1, Int(0.005 * sampleRate))
        for voice in 0..<6 {
            let base = 45.0 + 7.0 * Double(voice)
            var t = 0
            while t < n {
                let length = min(n - t, Int(durations[rng.index(durations.count)] * sampleRate))
                let midi = base + Double(rng.index(25)) - 12
                let f0 = 440 * pow(2, (midi - 69) / 12)
                let amplitude = 0.08 + 0.08 * rng.unit()
                let phase0 = rng.unit() * 2 * Double.pi
                for i in 0..<length {
                    let time = Double(i) / sampleRate
                    let envelope = (i < attack ? Double(i) / Double(attack) : 1) * exp(-time / 0.4)
                    var s = 0.0
                    for k in 1...5 {
                        let fk = f0 * Double(k)
                        if fk < sampleRate / 2 { s += sin(2 * Double.pi * fk * time + phase0 * Double(k)) / pow(Double(k), 1.2) }
                    }
                    out[t + i] += amplitude * envelope * s
                }
                t += max(1, length)
            }
        }
        let chirpAmplitude = pow(10, -24.0 / 20) * 2.0.squareRoot()
        let ratio = 20.0, f0 = 200.0
        for i in 0..<n {
            let tau = Double(i) / Double(max(1, n - 1))
            let phase = 2 * Double.pi * f0 * seconds * (pow(ratio, tau) - 1) / log(ratio)
            out[i] += chirpAmplitude * sin(phase)
        }
        let burstRMS = pow(10, -20.0 / 20)
        var position = Int(0.3 * sampleRate)
        while position < n {
            let length = Int((0.02 + 0.06 * rng.unit()) * sampleRate)
            for i in position..<min(n, position + length) { out[i] += burstRMS * AudioTransforms.gaussian(&rng) }
            position += Int((1.0 + rng.unit()) * sampleRate)
        }
        let bed = pow(10, -60.0 / 20)
        for i in 0..<n { out[i] += bed * AudioTransforms.gaussian(&rng) }
        let most = out.reduce(0) { max($0, abs($1)) }
        let scale = most > 0 ? peak / most : 1
        return AudioClip(sampleRate: sampleRate, mono: out.map { Float($0 * scale) })
    }

    public static func tone(frequency: Double, amplitude: Double, seconds: Double, sampleRate: Double) -> AudioClip {
        let n = Int(seconds * sampleRate)
        return AudioClip(sampleRate: sampleRate, mono: (0..<n).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / sampleRate)) })
    }

    public static func whiteNoise(seed: UInt64, rmsDBFS: Double, seconds: Double, sampleRate: Double) -> AudioClip {
        var rng = SplitMix64(seed: seed)
        let rms = pow(10, rmsDBFS / 20)
        let n = Int(seconds * sampleRate)
        return AudioClip(sampleRate: sampleRate, mono: (0..<n).map { _ in Float(rms * AudioTransforms.gaussian(&rng)) })
    }

    /// A click every quarter second from t = 0: a 5 ms burst of Gaussian noise at −12 dBFS over a −60 dBFS bed. The sharpest
    /// time grid the study can be handed, added on 2026-11-08 after the music-like control was judged, as a labelled extra.
    public static func clicks(seed: UInt64, seconds: Double, sampleRate: Double, every: Double = 0.25) -> AudioClip {
        var rng = SplitMix64(seed: seed)
        let n = Int(seconds * sampleRate), burst = Int(0.005 * sampleRate), bed = pow(10, -60.0 / 20), level = pow(10, -12.0 / 20)
        var out = (0..<n).map { _ in bed * AudioTransforms.gaussian(&rng) }
        var position = 0.0
        while Int(position) < n {
            for i in Int(position)..<min(n, Int(position) + burst) { out[i] += level * AudioTransforms.gaussian(&rng) }
            position += every * sampleRate
        }
        return AudioClip(sampleRate: sampleRate, mono: out.map { Float(min(1, max(-1, $0))) })
    }

    public static func silence(seconds: Double, sampleRate: Double) -> AudioClip {
        AudioClip(sampleRate: sampleRate, mono: [Float](repeating: 0, count: Int(seconds * sampleRate)))
    }

    /// The SHA-256 of the clip's channels as little-endian 16-bit samples, in channel order.
    public static func pcm16SHA256(_ clip: AudioClip) -> String {
        var data = Data()
        data.reserveCapacity(clip.frames * clip.channelCount * 2)
        for channel in clip.channels {
            for x in channel {
                let v = Int16(max(-32768, min(32767, (Double(x) * 32767).rounded())))
                withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        return ContentHash.sha256Hex(data)
    }
}
