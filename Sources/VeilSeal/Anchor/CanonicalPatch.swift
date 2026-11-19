//
//  CanonicalPatch.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: An anchor's neighbourhood as one fixed square, whatever the picture's size or turn: 32×32 RGB
//        samples (0–255) of a square 12σ wide, centred on the anchor and turned to its orientation. A
//        neighbourhood measure and the warp residual both read this square, so they read the same
//        neighbourhood in a picture and in a resized or rotated copy of it.
//  PIN:  Sampled bilinearly from the anchor's octave colour planes, edges extended; sample (u, v) sits
//        at ((u + ½ − 16)·d, (v + ½ − 16)·d) in the anchor's frame, d = 12σ / 32, turned by the angle
//        (x along the orientation). Interleaved R, G, B, row v first: WarpResidual.batch's [1024, 3].
//  ROBUSTNESS: Class I · Resizing; Class II · Photo of a photo — scale and rotation are divided out
//        here, which is what lets a 32 px residual and a fixed set of comparisons survive a resize.
//

import Foundation

enum CanonicalPatch {
    static let side = 32
    static let span: Float = 12

    /// Every anchor's square, one after another (count × 1024 × 3).
    static func cut(_ anchors: [FoundAnchor], from space: ScaleSpace) -> [Float] {
        let n = side * side * 3
        var out = [Float](repeating: 0, count: anchors.count * n)
        for (a, anchor) in anchors.enumerated() {
            let octave = min(anchor.octave, space.colour.count - 1)
            let scale = Float(1 << octave)
            let planes = space.colour[octave]
            let cx = anchor.x / scale, cy = anchor.y / scale
            let step = span * anchor.sigma / scale / Float(side)
            let c = cos(anchor.angle), s = sin(anchor.angle)
            var i = a * n
            for v in 0..<side {
                let dv = (Float(v) + 0.5 - Float(side) / 2) * step
                for u in 0..<side {
                    let du = (Float(u) + 0.5 - Float(side) / 2) * step
                    let x = cx + c * du - s * dv, y = cy + s * du + c * dv
                    out[i] = planes[0].sample(x, y)
                    out[i + 1] = planes[1].sample(x, y)
                    out[i + 2] = planes[2].sample(x, y)
                    i += 3
                }
            }
        }
        return out
    }
}
