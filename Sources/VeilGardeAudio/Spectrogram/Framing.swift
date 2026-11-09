//
//  Framing.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A signal cut into windowed frames for the FFT, and the per-sample window-square sum the
//        inverse divides by.
//  PIN:  Centre padding of N/2 zeros on both sides, so frames = 1 + ⌊L / hop⌋ and frame t is
//        centred on sample t · hop. Zeros, not a reflection, so a frame depends only on real
//        samples inside its span, and a cut's interior frames equal its source's. Frames are
//        row-major Float, count × N, each sample multiplied by the periodic Hann in Double and
//        rounded once.
//

import Foundation

public enum Framing {
    /// The windowed frames of `signal`, row-major count × N.
    public static func frames(_ signal: AnalysisSignal) -> (values: [Float], count: Int) {
        let p = signal.profile
        let N = p.fftSize, H = p.hop, pad = p.padding, L = signal.samples.count
        let count = p.frameCount(samples: L)
        let w = p.window
        var out = [Float](repeating: 0, count: count * N)
        signal.samples.withUnsafeBufferPointer { x in
            for t in 0..<count {
                let start = t * H - pad
                let base = t * N
                let n0 = max(0, -start), n1 = min(N, L - start)
                guard n0 < n1 else { continue }
                for n in n0..<n1 { out[base + n] = Float(x[start + n] * w[n]) }
            }
        }
        return (out, count)
    }

    /// Σ over the existing frames of w² at every padded sample, length (count − 1) · hop + N.
    public static func windowSquareSum(frames count: Int, profile p: SpectrogramProfile) -> [Double] {
        let N = p.fftSize, H = p.hop
        guard count > 0 else { return [] }
        let w2 = p.window.map { $0 * $0 }
        var sum = [Double](repeating: 0, count: (count - 1) * H + N)
        for t in 0..<count {
            let base = t * H
            for n in 0..<N { sum[base + n] += w2[n] }
        }
        return sum
    }
}
