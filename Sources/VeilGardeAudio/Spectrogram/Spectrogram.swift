//
//  Spectrogram.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The complex short-time Fourier transform of an analysis signal and its exact inverse, the
//        two places the carrier's arithmetic runs on the GPU; and the same transform with its
//        magnitudes replaced by a picture's, the original phase kept, for the way back from the
//        8-bit picture.
//  PIN:  Frigate's MLXFFT.rfft and irfft on float32 frames, in chunks of framesPerEval; the real
//        and imaginary parts come back as Float and everything else is Double on the CPU. The
//        inverse is the windowed overlap-add divided by the per-sample window-square sum over the
//        frames that exist (1.5 away from the ends), then the padding trimmed, so a signal comes
//        back to float precision. From a picture, each complex value is scaled by the dequantized
//        magnitude over its own; zero stays zero, and the DC bin, which the picture does not hold,
//        is set to zero. The chunk size does not change a value (SpectrogramTests).
//

import Foundation
import MLX
import VeilGardeLens

public struct Spectrogram: Sendable, Equatable {
    public let profile: SpectrogramProfile
    public let frames: Int
    /// N/2 + 1 complex bins per frame; the picture keeps bins 1…N/2.
    public let bins: Int
    public let sampleCount: Int
    /// Row-major frames × bins.
    public var real: [Float]
    public var imaginary: [Float]

    /// The transform of `signal`, `framesPerEval` frames an MLX call (the profile's budget unless a test asks).
    public init(_ signal: AnalysisSignal, framesPerEval: Int = SpectrogramProfile.framesPerEval) {
        defer { LensRuntime.releaseMemory() }
        let p = signal.profile
        let N = p.fftSize, B = N / 2 + 1
        let (values, count) = Framing.frames(signal)
        var re = [Float](repeating: 0, count: count * B)
        var im = re
        var t0 = 0
        while t0 < count {
            let t1 = min(t0 + max(1, framesPerEval), count)
            let chunk = MLXArray(Array(values[(t0 * N)..<(t1 * N)]), [t1 - t0, N])
            let x = MLXFFT.rfft(chunk, axis: 1)
            let r = x.realPart(), i = x.imaginaryPart()
            MLX.eval(r, i)
            re.replaceSubrange((t0 * B)..<(t1 * B), with: r.asArray(Float.self))
            im.replaceSubrange((t0 * B)..<(t1 * B), with: i.asArray(Float.self))
            t0 = t1
        }
        profile = p
        frames = count
        bins = B
        sampleCount = signal.samples.count
        real = re
        imaginary = im
    }

    public func magnitude(frame: Int, bin: Int) -> Double {
        let k = frame * bins + bin
        return hypot(Double(real[k]), Double(imaginary[k]))
    }

    /// The signal back, to float precision.
    public func inverse() -> AnalysisSignal {
        defer { LensRuntime.releaseMemory() }
        let N = profile.fftSize, H = profile.hop, B = bins, pad = profile.padding, count = frames
        guard count > 0 else { return AnalysisSignal(profile: profile, samples: []) }
        let w = profile.window
        var acc = [Double](repeating: 0, count: (count - 1) * H + N)
        var t0 = 0
        while t0 < count {
            let t1 = min(t0 + SpectrogramProfile.framesPerEval, count)
            let r = MLXArray(Array(real[(t0 * B)..<(t1 * B)]), [t1 - t0, B])
            let i = MLXArray(Array(imaginary[(t0 * B)..<(t1 * B)]), [t1 - t0, B])
            let y = MLXFFT.irfft(r + i.asImaginary(), n: N, axis: 1)
            MLX.eval(y)
            let f = y.asArray(Float.self)
            for t in t0..<t1 {
                let base = (t - t0) * N, j0 = t * H
                for n in 0..<N { acc[j0 + n] += Double(f[base + n]) * w[n] }
            }
            t0 = t1
        }
        let wss = Framing.windowSquareSum(frames: count, profile: profile)
        var out = [Double](repeating: 0, count: sampleCount)
        for s in 0..<sampleCount {
            let j = s + pad
            out[s] = wss[j] > 0 ? acc[j] / wss[j] : 0
        }
        return AnalysisSignal(profile: profile, samples: out)
    }

    /// The same phase under the picture's magnitudes.
    public func replacingMagnitudes(with image: SpectrogramImage) -> Spectrogram {
        precondition(image.width == frames && image.height == bins - 1, "the picture is \(image.width)×\(image.height), the spectrogram \(frames)×\(bins - 1)")
        var copy = self
        let B = bins
        for t in 0..<frames {
            copy.real[t * B] = 0
            copy.imaginary[t * B] = 0
            for bin in 1..<B {
                let k = t * B + bin
                let re = Double(real[k]), im = Double(imaginary[k])
                let m = hypot(re, im)
                let level = image.level(frame: t, bin: bin)
                if m == 0 || level == 0 {
                    copy.real[k] = 0
                    copy.imaginary[k] = 0
                    continue
                }
                let scale = GrayMapping.magnitude(level: level, profile: profile) / m
                copy.real[k] = Float(re * scale)
                copy.imaginary[k] = Float(im * scale)
            }
        }
        return copy
    }
}
