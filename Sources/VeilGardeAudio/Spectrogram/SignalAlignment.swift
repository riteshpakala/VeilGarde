//
//  SignalAlignment.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The integer lag between two signals, by cross-correlation through the FFT on the GPU, and
//        a signal shifted by that lag: how the acceptance verifies that a codec's decode came back
//        time-aligned, and corrects it when it did not.
//  PIN:  The correlation of the first 2²⁰ samples at most, zero-padded to a power of two; the lag
//        is the argmax over ±maximumLag, positive when the candidate is late. Empty input gives 0.
//

import Foundation
import MLX
import VeilGardeLens

public enum SignalAlignment {
    public static let maximumSamples = 1 << 20

    /// The lag by which `candidate` is late against `reference`: candidate[i + lag] ≈ reference[i].
    public static func lag(of candidate: [Float], against reference: [Float], maximumLag: Int = 4096) -> Int {
        guard !candidate.isEmpty, !reference.isEmpty, maximumLag > 0 else { return 0 }
        defer { LensRuntime.releaseMemory() }
        let a = Array(reference.prefix(maximumSamples)), b = Array(candidate.prefix(maximumSamples))
        let needed = max(a.count, b.count) + maximumLag
        var size = 1
        while size < needed { size <<= 1 }
        let spectrumA = MLXFFT.rfft(MLXArray(a + [Float](repeating: 0, count: size - a.count)))
        let spectrumB = MLXFFT.rfft(MLXArray(b + [Float](repeating: 0, count: size - b.count)))
        let correlation = MLXFFT.irfft(spectrumB * spectrumA.conjugate(), n: size)
        MLX.eval(correlation)
        let c = correlation.asArray(Float.self)
        var best = 0
        var bestValue = -Float.infinity
        for k in -maximumLag...maximumLag {
            let v = c[(k + size) % size]
            if v > bestValue {
                bestValue = v
                best = k
            }
        }
        return best
    }

    /// `candidate` advanced by `lag` and cut or zero-padded to `length`.
    public static func aligned(_ candidate: [Float], by lag: Int, length: Int) -> [Float] {
        var out = [Float](repeating: 0, count: max(0, length))
        for i in out.indices {
            let j = i + lag
            if j >= 0 && j < candidate.count { out[i] = candidate[j] }
        }
        return out
    }
}
