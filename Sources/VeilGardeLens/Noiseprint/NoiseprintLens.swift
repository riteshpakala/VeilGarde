//
//  NoiseprintLens.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The noiseprint CNN, a learned camera-provenance prior for the recompressed zone where the
//        capture peak reads absent: a Bayar-constrained 4-conv network scores a 4×4 grid of
//        128-px gray patches and their mean sigmoid is P(camera). It only ever subtracts
//        generated evidence in the combiner (its low side includes laundered web reals).
//  PIN:  Garde's noiseprint, unchanged: BN-folded convs 5×5 1→8 s1 p2, then 3×3 8→24, 24→48,
//        48→48 s2 p1, ReLU each, global average pool, linear 48→1; weights `conv{0..3}.weight/bias`
//        [O, kH, kW, I] and `linear.weight` [1, 48], `linear.bias` [1]. Input round(BT.601 luma)/255
//        at native size; patch origins round(i·(H−128)/3); patches with std ≤ 0.02 dropped.
//        Held-out ALL-AUC 0.941 native, 0.906 webp75 (the v202 measurement, quoted).
//

import CoreGraphics
import Foundation
import MLX
import MLXNN

public struct NoiseprintNet: @unchecked Sendable {
    public static let patch = 128
    let w: [MLXArray], b: [MLXArray]
    let linW: MLXArray, linB: MLXArray
    let strides = [1, 2, 2, 2]
    let pads = [2, 1, 1, 1]

    public init(weights: [String: MLXArray]) throws {
        var ws: [MLXArray] = [], bs: [MLXArray] = []
        for i in 0..<4 {
            guard let wi = weights["conv\(i).weight"], let bi = weights["conv\(i).bias"] else {
                throw VeilGardeFailure.data("the noiseprint weights have no conv\(i).weight/bias")
            }
            ws.append(wi); bs.append(bi)
        }
        guard let lw = weights["linear.weight"], let lb = weights["linear.bias"] else {
            throw VeilGardeFailure.data("the noiseprint weights have no linear.weight/bias")
        }
        self.w = ws; self.b = bs; self.linW = lw; self.linB = lb
    }

    /// patches [n, 128, 128, 1] in [0, 1] → mean sigmoid P(camera).
    public func score(_ patches: MLXArray) -> Float {
        var h = patches
        for i in 0..<4 { h = relu(conv2d(h, w[i], stride: IntOrPair(strides[i]), padding: IntOrPair(pads[i])) + b[i]) }
        h = h.mean(axes: [1, 2])
        let logits = matmul(h, linW.transposed()) + linB
        return sigmoid(logits).mean().item(Float.self)
    }
}

public final class NoiseprintLens: @unchecked Sendable {
    public static let shared = NoiseprintLens()
    private let lock = NSLock()
    private var loaded = false
    private var net: NoiseprintNet?

    /// The network, loaded once; nil when its weights are not found.
    public func get() -> NoiseprintNet? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            loaded = true
            if let url = WeightLocator.shared.url(.noiseprint), let arrays = try? loadArrays(url: url) { net = try? NoiseprintNet(weights: arrays) }
        }
        return net
    }

    /// P(camera), or nil when the net is absent or the image is smaller than a patch or blank.
    public static func score(_ cg: CGImage) -> Float? {
        guard let net = shared.get(), let (g, w, h) = grayPlane(cg), let patches = gridPatches(g, w, h) else { return nil }
        return net.score(patches)
    }

    /// The gray [0, 1] plane at native size: round(BT.601 luma) / 255.
    public static func grayPlane(_ cg: CGImage) -> (g: [Float], w: Int, h: Int)? {
        let n = NoiseprintNet.patch
        guard cg.width >= n, cg.height >= n, let (bytes, w, h) = grayBytes(cg) else { return nil }
        return (bytes.map { Float($0) / 255.0 }, w, h)
    }

    /// The same plane as bytes, round(BT.601 luma): what the trainer stores its patches as
    /// (exactly, since every gray value is k / 255).
    public static func grayBytes(_ cg: CGImage) -> (g: [UInt8], w: Int, h: Int)? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var g = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(px[i * 4]), gg = Float(px[i * 4 + 1]), bb = Float(px[i * 4 + 2])
            g[i] = UInt8((0.299 * r + 0.587 * gg + 0.114 * bb).rounded())
        }
        return (g, w, h)
    }

    /// The deterministic 4×4 patch grid, blank patches dropped.
    public static func gridPatches(_ g: [Float], _ w: Int, _ h: Int) -> MLXArray? {
        guard let (rows, count) = gridPatchValues(g, w, h) else { return nil }
        let n = NoiseprintNet.patch
        return MLXArray(rows, [count, n, n, 1])
    }

    /// The same grid as host values, row-major patch after patch (the trainer prepares these on
    /// many threads and hands them to the GPU on one).
    public static func gridPatchValues(_ g: [Float], _ w: Int, _ h: Int) -> (values: [Float], count: Int)? {
        let n = NoiseprintNet.patch
        guard w >= n, h >= n else { return nil }
        var rows = [Float]()
        var count = 0
        for i in 0..<4 {
            for j in 0..<4 {
                let yy = Int((Double(i) * Double(h - n) / 3.0).rounded())
                let xx = Int((Double(j) * Double(w - n) / 3.0).rounded())
                var patch = [Float]()
                patch.reserveCapacity(n * n)
                var sum: Float = 0, sq: Float = 0
                for py in 0..<n {
                    let base = (yy + py) * w + xx
                    for px in 0..<n { let v = g[base + px]; patch.append(v); sum += v; sq += v * v }
                }
                let count2 = Float(n * n)
                let variance = max(0, sq / count2 - (sum / count2) * (sum / count2))
                if variance.squareRoot() > 0.02 { rows += patch; count += 1 }
            }
        }
        guard count > 0 else { return nil }
        return (rows, count)
    }
}
