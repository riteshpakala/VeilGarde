//
//  DirectionalProbes.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The v2.6 directional-response signature (columns 20–40): the high-pass residual energy
//        of eight controlled whole-image warps (translate x and y, shear x and y, two diagonals,
//        scale, rotate) at two strengths, plus five log-ratios between them. Read only when the
//        loaded model has more than 19 columns; the shipped 19-column model never runs it.
//  PIN:  The v4_a1_tilesig reference `_tile_sig`: magnitude m = s · min(W, H) in float64 then cast,
//        strengths [0.025, 0.05] (the A2 round refuted a longer ladder), probe and column order
//        are layout law, the same inv(M) / inv(inv(M)) double inversion as the tile warps, and
//        Rhp = |R − GaussianBlur(R, 9, σ 1.5)| (absolute, unlike the tile residual). Each probe
//        builds and frees its own one-trial table pair (≈33 MB at 512²).
//

import MLX
import MLXAccelerate

enum DirectionalProbes {
    static let strengths: [Double] = [0.025, 0.05]
    static let epsilon: Float = 1e-7

    /// The 8 probes as whole-image corner displacements at magnitude m, corners [[0,0],[W,0],[W,H],[0,H]].
    static func displacements(m: Float) -> [[[Float]]] {
        [
            [[m, 0], [m, 0], [m, 0], [m, 0]],          // tx
            [[0, m], [0, m], [0, m], [0, m]],          // ty
            [[m, 0], [m, 0], [-m, 0], [-m, 0]],        // shx
            [[0, m], [0, -m], [0, -m], [0, m]],        // shy
            [[m, m], [m, m], [m, m], [m, m]],          // diag1
            [[m, -m], [m, -m], [m, -m], [m, -m]],      // diag2
            [[-m, -m], [m, -m], [m, m], [-m, m]],      // scale
            [[0, -m], [m, 0], [0, m], [-m, 0]],        // rot
        ]
    }

    /// 21 arrays of [TR·TC], in the model's column order.
    static func compute(img: MLXArray, H: Int, W: Int, TR: Int, TC: Int, quantizeLikeCV2: Bool) -> [MLXArray] {
        let ts = WarpConstants.tileSize
        let src: [[Float]] = [[0, 0], [Float(W), 0], [Float(W), Float(H)], [0, Float(H)]]
        let flat = img.reshaped([1, H * W, 3])
        var E = [MLXArray]()
        for s in strengths {
            let m = Float(s * Double(min(W, H)))
            for d in displacements(m: m) {
                let dst: [[Float]] = (0..<4).map { [src[$0][0] + d[$0][0], src[$0][1] + d[$0][1]] }
                let M = getPerspectiveTransformD(src: src, dst: dst)
                let fwd = buildBicubicWarpTable(dstToSrc: [invertMatrix3x3D(M)], height: H, width: W, sourceIsTrialStacked: false, quantizeLikeCV2: quantizeLikeCV2)
                let back = buildBicubicWarpTable(dstToSrc: [invertMatrix3x3D(invertMatrix3x3D(M))], height: H, width: W, sourceIsTrialStacked: true, quantizeLikeCV2: quantizeLikeCV2)
                let rt = applyWarpTable(applyWarpTable(flat, fwd), back)
                let R = MLX.abs(flat - rt).mean(axes: [2]).reshaped([1, H, W])
                let Rhp = MLX.abs(R - batchedGaussianBlur(R, kernelSize: WarpConstants.highPassKernel, sigma: WarpConstants.highPassSigma))
                let e = Rhp[0..., 0..<(TR * ts), 0..<(TC * ts)].reshaped([1, TR, ts, TC, ts]).mean(axes: [2, 4]).reshaped([TR * TC])
                MLX.eval(e)
                E.append(e)
            }
        }
        let eps = MLXArray(epsilon)
        func lg(_ a: MLXArray, _ b: MLXArray) -> MLXArray { MLX.log((a + eps) / (b + eps)) }
        let e0mean = E[0..<8].reduce(MLXArray(Float(0)), +) / Float(8)
        let e1mean = E[8..<16].reduce(MLXArray(Float(0)), +) / Float(8)
        let derived = [
            lg(E[0], E[1]),                    // log(tx / ty) at s1
            lg(E[8], E[9]),                    // log(tx / ty) at s2
            lg(E[8] + E[9], E[12] + E[13]),    // log(axial / diagonal) at s2
            lg(E[10], E[11]),                  // log(shx / shy) at s2
            lg(e1mean, e0mean),                // control slope
        ]
        return E + derived
    }
}
