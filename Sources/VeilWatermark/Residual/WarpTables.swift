//
//  WarpTables.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The residual's precomputed gathers. Every tile is 32×32 and the 16 homographies are
//        constants, so each warp's sample indices and bicubic weights are content-independent:
//        built once (host-side, float64) as Frigate WarpTapTables, then every tile batch warps in
//        16 large gathers. The inverse warp's indices are offset per trial so it samples the
//        trial-stacked forward output in the same single round.
//  PIN:  the Python reference, per trial: M = getPerspectiveTransform(src, src + d); the forward warp hands M to cv2,
//        which inverts it; the back warp hands inv(M), which cv2 inverts again. So the dst→src
//        maps are inv(M) and inv(inv(M)), both kept in float64, the double inversion included (do
//        not shortcut to M). cv2 bicubic A = −0.75, reflect-101, and with `quantizeLikeCV2` its
//        1/32-pixel fixed-point coordinates: Frigate's buildBicubicWarpTable does all of it.
//

import Foundation
import MLX
import MLXAccelerate

public struct WarpTables {
    public let lowForward: WarpTapTable
    public let lowBack: WarpTapTable
    public let highForward: WarpTapTable
    public let highBack: WarpTapTable
    public let quantizeLikeCV2: Bool

    public init(quantizeLikeCV2: Bool) {
        self.quantizeLikeCV2 = quantizeLikeCV2
        (lowForward, lowBack) = Self.build(scale: WarpConstants.lowStrengthD, quantizeLikeCV2: quantizeLikeCV2)
        (highForward, highBack) = Self.build(scale: WarpConstants.highStrengthD, quantizeLikeCV2: quantizeLikeCV2)
    }

    /// The (forward, inverse) tap tables for the 16 trials at strength `s`.
    static func build(scale s: Double, quantizeLikeCV2: Bool) -> (fwd: WarpTapTable, back: WarpTapTable) {
        let ts = WarpConstants.tileSize
        let t = Float(ts)
        let srcCorners: [[Float]] = [[0, 0], [t, 0], [t, t], [0, t]]
        var fwdMats = [[Double]]()
        var backMats = [[Double]]()
        for trial in 0..<WarpConstants.trials {
            let dst: [[Float]] = (0..<4).map { c in
                // float64 multiply, then cast to Float: numpy's `.astype(np.float32)`.
                let dx = Float(WarpDisplacements.table[trial][c][0] * s * Double(ts))
                let dy = Float(WarpDisplacements.table[trial][c][1] * s * Double(ts))
                return [srcCorners[c][0] + dx, srcCorners[c][1] + dy]
            }
            let M = getPerspectiveTransformD(src: srcCorners, dst: dst)
            fwdMats.append(invertMatrix3x3D(M))
            backMats.append(invertMatrix3x3D(invertMatrix3x3D(M)))
        }
        let fwd = buildBicubicWarpTable(dstToSrc: fwdMats, height: ts, width: ts, sourceIsTrialStacked: false, quantizeLikeCV2: quantizeLikeCV2)
        let back = buildBicubicWarpTable(dstToSrc: backMats, height: ts, width: ts, sourceIsTrialStacked: true, quantizeLikeCV2: quantizeLikeCV2)
        return (fwd, back)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [Bool: WarpTables] = [:]

    /// The tables for one quantization mode, built once per process (they are constants).
    public static func shared(quantizeLikeCV2: Bool) -> WarpTables {
        lock.lock()
        defer { lock.unlock() }
        if let tables = cached[quantizeLikeCV2] { return tables }
        let tables = WarpTables(quantizeLikeCV2: quantizeLikeCV2)
        cached[quantizeLikeCV2] = tables
        return tables
    }
}
