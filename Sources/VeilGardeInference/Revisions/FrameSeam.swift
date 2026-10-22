//
//  FrameSeam.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The frame-seam revision (v3.3, live): a fake analog or film border drags the pooled
//        evidence real-ward while the synthetic content hides inside. When the verdict is real,
//        capture is absent and P ≥ 0.10, detect a uniform dark frame, run the whole pipeline once
//        on a wide interior crop that keeps the frame-to-content seam, and take decisive interior
//        evidence (interior ≥ 0.70 and at least 0.20 above P).
//  PIN:  The frame detector, unchanged: a 96×96 luma grid, bands of 3% that qualify when dark
//        (mean < 0.16), uniform (sd < 0.17) and darker than the interior by > 0.12, at least two
//        qualifying sides, then the fixed rect (5%, 2%, 90%, 96%). The P ≥ 0.10 floor was
//        re-validated 2026-07-19; real film scans read ≤ 0.01 under this rect (6 of 6). The crop
//        is rendered as a fresh bitmap (renderCrop), never cropping(to:). The inner run's own
//        frame seam is skipped (InferenceConfig.skipFrameCheck), so it recurses once.
//

import CoreGraphics
import Foundation

public struct FrameSeam: Revision {
    public let name = "frame-seam"

    public init() {}

    public func apply(_ v: inout WorkingVerdict, stack: [MemberOutput], signals s: DetectionSignals, pipeline: Pipeline) throws -> RevisionRecord {
        let present = stack.member("capture")?.flag("present") ?? false
        func skipped() -> RevisionRecord {
            RevisionRecord(name: name, applied: false, p: v.p, prediction: v.prediction,
                           fields: [Field("interior_p", .absent), Field("decisive", .flag(false))])
        }
        guard !s.config.skipFrameCheck, v.prediction == "real", !present, v.p >= 0.10,
              let interiorRect = Self.detectFrame(s.cgImage), let interior = ImageLoading.renderCrop(s.cgImage, interiorRect) else { return skipped() }
        var cfg = s.config
        cfg.skipFrameCheck = true
        let pi = try pipeline.run(cgImage: interior, config: cfg).p
        let decisive = pi >= 0.70 && (pi - v.p) >= 0.20
        if decisive {
            v.prediction = "generated"
            v.p = pi
        }
        return RevisionRecord(name: name, applied: decisive, p: v.p, prediction: v.prediction,
                              fields: [Field("interior_p", .number(pi)), Field("decisive", .flag(decisive))])
    }

    /// The interior rect when the image wears an analog or film frame, else nil.
    static func detectFrame(_ image: CGImage) -> CGRect? {
        let N = 96
        var buf = [UInt8](repeating: 0, count: N * N)
        guard let ctx = CGContext(data: &buf, width: N, height: N, bitsPerComponent: 8, bytesPerRow: N,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: N, height: N))
        func stats(_ xs: Range<Int>, _ ys: Range<Int>) -> (mean: Float, sd: Float) {
            var s: Float = 0, s2: Float = 0, n: Float = 0
            for y in ys { for x in xs { let v = Float(buf[y * N + x]) / 255; s += v; s2 += v * v; n += 1 } }
            let m = s / max(n, 1)
            return (m, max(0, s2 / max(n, 1) - m * m).squareRoot())
        }
        // CGContext.draw has a bottom-left origin: buffer row 0 is the IMAGE BOTTOM.
        let b = Int(Float(N) * 0.03)
        let interior = stats(b * 4 ..< N - b * 4, b * 4 ..< N - b * 4)
        func qualifies(_ s: (mean: Float, sd: Float)) -> Bool { s.mean < 0.16 && s.sd < 0.17 && (interior.mean - s.mean) > 0.12 }
        let imgTop = qualifies(stats(0 ..< N, N - b ..< N))
        let imgBottom = qualifies(stats(0 ..< N, 0 ..< b))
        let left = qualifies(stats(0 ..< b, 0 ..< N))
        let right = qualifies(stats(N - b ..< N, 0 ..< N))
        guard [imgTop, imgBottom, left, right].filter({ $0 }).count >= 2 else { return nil }
        let W = CGFloat(image.width), H = CGFloat(image.height)
        return CGRect(x: W * 0.05, y: H * 0.02, width: W * 0.90, height: H * 0.96)
    }
}
