//
//  CaptureFeatures.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The camera-capture signature: a real sensor's Bayer mosaic and demosaicing leave a
//        high-frequency peak near Nyquist in the residual power spectrum that no generator
//        reproduces. Nine values feed the fusion head; four of them (peak, valid, native size,
//        present) are what the verdict and the trust law read.
//  PIN:  Computed at NATIVE resolution on a centre crop (Lens/Capture): a single 2× downsample
//        destroys it, so `valid` requires a native short side of 512. `present` needs peak ≥ 30,
//        Swift's threshold since 2026-07-11 (the Python reference used 20; the [20, 30) band held only
//        AI-video re-encodes). The order of the nine is capture_signature.py's
//        CAPTURE_FEATURE_NAMES and the fusion head's columns 386–394.
//

/// What the verdict and the trust law read from the capture signature.
public struct CaptureSignature: Sendable, Equatable, Codable {
    /// Radial high-frequency spectral peakiness: max over median of the outer radial profile.
    public let peak: Float
    /// The native short side reached the reliability floor (512 px).
    public let valid: Bool
    /// The native short side in pixels.
    public let nativePixels: Int
    /// valid and peak ≥ 30: a real-sensor signature is present.
    public let present: Bool

    public init(peak: Float, valid: Bool, nativePixels: Int, present: Bool) {
        self.peak = peak
        self.valid = valid
        self.nativePixels = nativePixels
        self.present = present
    }
}

/// The capture law's constants, read by the extractor (Lens) and the router (Inference) alike.
public enum CaptureLaw {
    /// The centre crop's side cap, in native pixels.
    public static let analysisSide = 1024
    /// The native short side below which the signature is not reliable.
    public static let minNativePixels = 512
    /// The peak at or above which a valid signature counts as present.
    public static let decisionPeak: Float = 30
    /// The high-pass the residual is taken with: gray − GaussianBlur(7×7, σ = 1).
    public static let highPassKernel = 7
    public static let highPassSigma: Float = 1
    /// The ceiling on P(AI) when a valid signature is present on the screenshot surfaces (the
    /// router's screenshot domain and the screenshot head). Never applied to the camera verdict,
    /// where capture-present only suppresses the specialists' gen-side evidence.
    public static let realCeiling: Float = 0.10
}

/// The nine values the fusion head reads, in its column order.
public struct CaptureFeatures: Sendable, Equatable, Codable {
    public var peak: Float
    public var valid: Float
    public var present: Float
    public var nativePixels: Float
    /// Standard deviation of the high-pass residual.
    public var residualStd: Float
    /// Share of spectral energy in the outer half of the radial profile.
    public var highFrequencyRatio: Float
    /// Spectral flatness of the outer three quarters of the profile.
    public var spectralFlatness: Float
    /// Spread of the 2×2 Bayer sub-grid variances of the residual.
    public var cfaTrace: Float
    /// Lag-1 horizontal autocorrelation of the residual.
    public var lag1: Float

    public static let count = 9
    public static let names = ["peak", "valid", "present", "native_px", "res_std", "hf_ratio", "spec_flat", "cfa_trace", "ac_lag1"]

    /// What an undecodable or too-small image yields: zeros, so a fusion row stays aligned.
    public static let zero = CaptureFeatures(vector: [Float](repeating: 0, count: count))

    public var asVector: [Float] { [peak, valid, present, nativePixels, residualStd, highFrequencyRatio, spectralFlatness, cfaTrace, lag1] }

    public init(vector: [Float]) {
        precondition(vector.count == Self.count, "a capture row has \(Self.count) values")
        peak = vector[0]; valid = vector[1]; present = vector[2]; nativePixels = vector[3]
        residualStd = vector[4]; highFrequencyRatio = vector[5]; spectralFlatness = vector[6]; cfaTrace = vector[7]; lag1 = vector[8]
    }

    /// The signature the verdict reads, derived from the same nine values.
    public var signature: CaptureSignature {
        CaptureSignature(peak: peak, valid: valid > 0.5, nativePixels: Int(nativePixels), present: present > 0.5)
    }
}
