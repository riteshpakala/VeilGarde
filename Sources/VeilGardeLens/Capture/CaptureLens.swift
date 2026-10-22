//
//  CaptureLens.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The camera-capture signature, computed: a square centre crop at native resolution (at most
//        1024 px), its luma high-pass residual, the residual's power spectrum and radial profile;
//        the profile's outer-half peak over its median is the Nyquist peak a Bayer mosaic leaves.
//        Nine values for the camera head, four for the capture member, from one measurement.
//  PIN:  Garde's captureCompute, unchanged (Python capture_signature.py): gray = 0.299R + 0.587G +
//        0.114B in float (not cv2's uint8 gray), residual = gray − GaussianBlur(7, σ 1) reflect-101,
//        mean removed; |fftshift(fft2)|²; numpy-bincount radial profile; peak = max(outer half) /
//        (median + 1e-12); spectral flatness over prof[n/4…]; CFA trace over the 2×2 sub-grids;
//        lag-1 correlation on every fifth pair. Aggregates in Double, host-side, for parity.
//

import CoreGraphics
import Foundation
import MLX
import MLXAccelerate
import MLXFFT

public enum CaptureLens {
    /// Both forms from one measurement: the nine values (zeros when the image cannot be measured)
    /// and the signature (then valid by the native size alone, never present).
    public static func reading(_ cgImage: CGImage) -> CaptureReading {
        guard let features = compute(cgImage) else {
            return CaptureReading(features: .zero, signature: CaptureSignature(
                peak: 0, valid: cgImage.width >= CaptureLaw.minNativePixels && cgImage.height >= CaptureLaw.minNativePixels,
                nativePixels: min(cgImage.width, cgImage.height), present: false))
        }
        return CaptureReading(features: features, signature: features.signature)
    }

    /// The nine values the camera head reads.
    public static func features(_ cgImage: CGImage) -> CaptureFeatures { reading(cgImage).features }

    /// The signature the capture member reports.
    public static func signature(_ cgImage: CGImage) -> CaptureSignature { reading(cgImage).signature }

    static func compute(_ cgImage: CGImage) -> CaptureFeatures? {
        let W = cgImage.width, H = cgImage.height
        let nativePx = min(W, H)
        var win = min(min(W, H), CaptureLaw.analysisSide)
        win -= win % 2
        guard win >= 8 else { return nil }

        let x0 = (W - win) / 2, y0 = (H - win) / 2
        let bpp = 4
        var px = [UInt8](repeating: 0, count: win * win * bpp)
        guard let ctx = CGContext(data: &px, width: win, height: win, bitsPerComponent: 8, bytesPerRow: win * bpp,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: -x0, y: -(H - win - y0), width: W, height: H))

        var gray = [Float](repeating: 0, count: win * win)
        for i in 0..<(win * win) {
            let b = i * bpp
            gray[i] = 0.299 * Float(px[b]) + 0.587 * Float(px[b + 1]) + 0.114 * Float(px[b + 2])
        }

        let g = MLXArray(gray, [win, win])
        let blurred = batchedGaussianBlur(g.reshaped([1, win, win]), kernelSize: CaptureLaw.highPassKernel,
                                          sigma: CaptureLaw.highPassSigma, border: .reflect101).reshaped([win, win])
        var R = g - blurred
        R = R - R.mean()
        let spec = MLXFFT.fft2(R.asType(.float32))
        let mag = MLXFFT.fftshift(MLX.abs(spec))
        let power = mag * mag
        MLX.eval(R, power)
        let res = R.asArray(Float.self)
        let P = power.asArray(Float.self)

        let prof = radialProfile(P, h: win, w: win)
        let n = prof.count
        let hf = Array(prof[(n / 2)...])
        let peak = hf.isEmpty ? 0 : Float(hf.max()! / (median(hf) + 1e-12))
        let profSum = prof.reduce(0, +)
        let hfRatio = Float(hf.reduce(0, +) / (profSum + 1e-12))
        let band = Array(prof[(n / 4)...])
        let geo = exp(band.reduce(0.0) { $0 + log($1 + 1e-12) } / Double(band.count))
        let specFlat = Float(geo / (band.reduce(0, +) / Double(band.count) + 1e-12))

        let resStd = stddev(res)
        let cfaTrace = cfaSubgridTrace(res, win: win)
        let acLag1 = lag1HorizCorr(res, win: win)

        let valid: Float = nativePx >= CaptureLaw.minNativePixels ? 1 : 0
        let present: Float = (valid > 0 && peak >= CaptureLaw.decisionPeak) ? 1 : 0
        return CaptureFeatures(vector: [peak, valid, present, Float(nativePx), resStd, hfRatio, specFlat, cfaTrace, acLag1])
    }

    /// numpy: rr = sqrt((y−cy)² + (x−cx)²).astype(int); prof = bincount(rr, P) / max(bincount(rr), 1).
    static func radialProfile(_ P: [Float], h: Int, w: Int) -> [Double] {
        let cy = h / 2, cx = w / 2
        let maxR = Int((Double(cy * cy + cx * cx)).squareRoot())
        var sums = [Double](repeating: 0, count: maxR + 1)
        var counts = [Int](repeating: 0, count: maxR + 1)
        for i in 0..<h {
            let dy2 = (i - cy) * (i - cy), rowBase = i * w
            for j in 0..<w {
                let dx = j - cx
                let r = Int((Double(dy2 + dx * dx)).squareRoot())
                sums[r] += Double(P[rowBase + j]); counts[r] += 1
            }
        }
        return (0...maxR).map { sums[$0] / Double(max(counts[$0], 1)) }
    }

    /// Population std (numpy .std(), ddof 0).
    static func stddev(_ a: [Float]) -> Float {
        let n = Double(a.count)
        guard n > 0 else { return 0 }
        var m = 0.0
        for v in a { m += Double(v) }
        m /= n
        var s = 0.0
        for v in a { let d = Double(v) - m; s += d * d }
        return Float((s / n).squareRoot())
    }

    /// (max − min) / mean of the four strided 2×2 sub-grid population variances.
    static func cfaSubgridTrace(_ res: [Float], win: Int) -> Float {
        var vars4 = [Double]()
        vars4.reserveCapacity(4)
        for a in 0..<2 {
            for b in 0..<2 {
                var m = 0.0, c = 0.0
                var i = a
                while i < win { var j = b; while j < win { m += Double(res[i * win + j]); c += 1; j += 2 }; i += 2 }
                m /= max(c, 1)
                var s = 0.0
                i = a
                while i < win { var j = b; while j < win { let d = Double(res[i * win + j]) - m; s += d * d; j += 2 }; i += 2 }
                vars4.append(s / max(c, 1))
            }
        }
        let mn = vars4.min()!, mx = vars4.max()!, mean = vars4.reduce(0, +) / 4.0
        return Float((mx - mn) / (mean + 1e-9))
    }

    /// Pearson of res[:, :-1].ravel()[::5] against res[:, 1:].ravel()[::5].
    static func lag1HorizCorr(_ res: [Float], win: Int) -> Float {
        var xs = [Double](), ys = [Double]()
        let total = win * (win - 1)
        xs.reserveCapacity(total / 5 + 1); ys.reserveCapacity(total / 5 + 1)
        var k = 0
        for i in 0..<win {
            let base = i * win
            for j in 0..<(win - 1) {
                if k % 5 == 0 { xs.append(Double(res[base + j])); ys.append(Double(res[base + j + 1])) }
                k += 1
            }
        }
        let n = Double(xs.count)
        guard n > 1 else { return 0 }
        var mx = 0.0, my = 0.0
        for t in 0..<xs.count { mx += xs[t]; my += ys[t] }
        mx /= n; my /= n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for t in 0..<xs.count { let dx = xs[t] - mx, dy = ys[t] - my; sxy += dx * dy; sxx += dx * dx; syy += dy * dy }
        let den = (sxx * syy).squareRoot()
        return den > 1e-12 ? Float(sxy / den) : 0
    }

    /// numpy.median: the mean of the two middle elements for an even count.
    static func median(_ a: [Double]) -> Double {
        let s = a.sorted(), n = s.count
        if n == 0 { return 0 }
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
}
