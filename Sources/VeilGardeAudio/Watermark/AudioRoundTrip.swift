//
//  AudioRoundTrip.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The picture back to sound, two ways, and how far the sound moved: the exact path, the
//        untouched complex transform inverted; and the image path, the magnitudes dequantized from
//        the 8-bit picture under the original phase. The metrics: SNR, the largest sample error and
//        the log-spectral deviation.
//  PIN:  SNR = 10·log10(Σx² / Σ(x − y)²) over the shorter length, infinite when the error is zero;
//        the deviation is the RMS over frames and bins of 20·log10(|Y| / |X|) where both sit at or
//        above the floor's magnitude. The bars fixed before measuring: exact ≥ 90 dB and max error
//        ≤ 1e-4 (float32 FFTs give about 110 dB); image ≥ 30 dB and deviation ≤ 0.2 dB (a 0.376 dB
//        step gives about 38 dB). The name logSpectralDeviation stays clear of Frigate's
//        spectralDistance.
//

import Foundation

public struct AudioRoundTripMetrics: Codable, Sendable, Equatable {
    public var samples: Int
    public var snrDB: Double
    public var maxAbsoluteError: Double
    public var logSpectralDeviationDB: Double

    public init(samples: Int, snrDB: Double, maxAbsoluteError: Double, logSpectralDeviationDB: Double) {
        self.samples = samples
        self.snrDB = snrDB
        self.maxAbsoluteError = maxAbsoluteError
        self.logSpectralDeviationDB = logSpectralDeviationDB
    }

    /// `candidate` against `reference`; the reference's spectrogram is reused when given.
    public static func measure(reference: AnalysisSignal, candidate: AnalysisSignal, referenceSpectrogram: Spectrogram? = nil) -> AudioRoundTripMetrics {
        let n = min(reference.samples.count, candidate.samples.count)
        var signal = 0.0, noise = 0.0, worst = 0.0
        for i in 0..<n {
            let x = reference.samples[i], d = candidate.samples[i] - x
            signal += x * x
            noise += d * d
            worst = max(worst, abs(d))
        }
        let snr: Double = noise == 0 ? .infinity : (signal == 0 ? -.infinity : 10 * log10(signal / noise))
        let a = referenceSpectrogram ?? Spectrogram(reference)
        let b = Spectrogram(candidate)
        return AudioRoundTripMetrics(samples: n, snrDB: snr, maxAbsoluteError: worst, logSpectralDeviationDB: logSpectralDeviation(a, b))
    }

    /// The RMS of the dB difference over the bins both spectrograms hold at or above the floor.
    public static func logSpectralDeviation(_ a: Spectrogram, _ b: Spectrogram) -> Double {
        let frames = min(a.frames, b.frames), B = min(a.bins, b.bins)
        let floor = a.profile.magnitudeReference * pow(10, SpectrogramProfile.floorDB / 20)
        var sum = 0.0
        var count = 0
        for t in 0..<frames {
            for k in 1..<B {
                let ma = a.magnitude(frame: t, bin: k), mb = b.magnitude(frame: t, bin: k)
                guard ma >= floor, mb >= floor else { continue }
                let d = 20 * log10(mb / ma)
                sum += d * d
                count += 1
            }
        }
        return count > 0 ? (sum / Double(count)).squareRoot() : 0
    }
}

public enum AudioRoundTrip {
    /// The exact path: the complex transform and back.
    public static func exact(_ signal: AnalysisSignal) -> (signal: AnalysisSignal, metrics: AudioRoundTripMetrics) {
        let spectrogram = Spectrogram(signal)
        let back = spectrogram.inverse()
        return (back, .measure(reference: signal, candidate: back, referenceSpectrogram: spectrogram))
    }

    /// The image path: the picture's magnitudes under the original phase, and back.
    public static func throughImage(_ signal: AnalysisSignal) -> (signal: AnalysisSignal, image: SpectrogramImage, metrics: AudioRoundTripMetrics) {
        let spectrogram = Spectrogram(signal)
        let image = SpectrogramImage(spectrogram)
        let back = spectrogram.replacingMagnitudes(with: image).inverse()
        return (back, image, .measure(reference: signal, candidate: back, referenceSpectrogram: spectrogram))
    }
}
