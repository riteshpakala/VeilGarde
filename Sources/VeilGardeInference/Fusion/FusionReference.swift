//
//  FusionReference.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The frozen fusion reference and what the mechanisms ask of it: the base probability with
//        the capture-validity shortcut neutralized (the preview tail), and the base probability of
//        four quadrants and a centre crop (zoom escalation).
//  PIN:  Garde's neutralizedBaseP and zoomCropEvidence. The mechanisms calibrate against the
//        REFERENCE (900 trees, never promoted over), not the live head, because a live base change
//        silently moved their operating points (measured, fb24); the live head is the fallback only when
//        a bundle has no reference. Neutralizing sets valid = 1 and native px = max(·, 576): the
//        2026-07-17 finding that invalid-capture rows were 85.5% generated taught the base
//        "small ⇒ AI". Zoom crops use cropping(to:), as Garde's did.
//

import CoreGraphics
import Foundation

enum FusionReference {
    static func modelURL(_ config: InferenceConfig) -> URL? { config.bundle.url(.fusionReference) ?? config.bundle.url(.fusionHead) }

    /// The reference base probability with the capture-validity flags neutralized.
    static func neutralizedBaseP(_ s: DetectionSignals) -> Float? {
        var cfg = s.config
        cfg.useFusion = false
        guard let warp = try? WarpInference.run(cgImage: s.cgImage, config: cfg),
              let emb = try? SemanticLens.fusionEmbedding(s.cgImage, variant: s.config.dinoVariant),
              let url = modelURL(s.config), let head = try? TreeModelCache.shared.model(url) else { return nil }
        var cap = CaptureLens.features(s.cgImage).asVector
        if cap.count >= 4 { cap[1] = 1.0; cap[3] = max(cap[3], 576.0) }
        let sh = warp.sharpness
        let sharp: [Float] = [sh?.salientSharp ?? 0, sh?.globalSharp ?? 0, sh?.sharpRatio ?? 0]
        return head.predict([warp.weightedScore] + emb + cap + sharp)
    }

    /// The reference base probability over four quadrants and the centre 60%: the largest, and how
    /// many reach 0.60.
    static func zoomCropEvidence(_ cgImage: CGImage, config: InferenceConfig) -> (maxP: Float, corroborating: Int)? {
        let W = cgImage.width, H = cgImage.height
        guard W >= 128, H >= 128 else { return nil }
        var cfg = config
        cfg.warp.nativeCheck = false
        let rects = [CGRect(x: 0, y: 0, width: W / 2, height: H / 2),
                     CGRect(x: W / 2, y: 0, width: W - W / 2, height: H / 2),
                     CGRect(x: 0, y: H / 2, width: W / 2, height: H - H / 2),
                     CGRect(x: W / 2, y: H / 2, width: W - W / 2, height: H - H / 2),
                     CGRect(x: Int(Double(W) * 0.2), y: Int(Double(H) * 0.2), width: Int(Double(W) * 0.6), height: Int(Double(H) * 0.6))]
        var best: Float? = nil
        var above = 0
        for r in rects {
            guard let crop = cgImage.cropping(to: r),
                  let warp = try? WarpInference.run(cgImage: crop, config: cfg),
                  let emb = try? SemanticLens.fusionEmbedding(crop, variant: config.dinoVariant) else { continue }
            let capv = CaptureLens.features(crop).asVector
            let sh = warp.sharpness
            let sharp: [Float] = [sh?.salientSharp ?? 0, sh?.globalSharp ?? 0, sh?.sharpRatio ?? 0]
            guard let url = modelURL(config), let head = try? TreeModelCache.shared.model(url) else { continue }
            let bp = head.predict([warp.weightedScore] + emb + capv + sharp)
            best = max(best ?? bp, bp)
            if bp >= 0.60 { above += 1 }
        }
        guard let b = best else { return nil }
        return (b, above)
    }
}
