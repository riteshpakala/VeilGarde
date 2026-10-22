//
//  Dinov2ViT.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: DINOv2-small (ViT-S/14) in MLXNN: the semantic half of VeilGarde. Its 384-value CLS embedding
//        feeds the camera head (what the image depicts, beside whether a sensor made it), its
//        256 patch tokens feed the semantic-tile head, and the same CLS after a 360×640
//        force-resize feeds every specialist head.
//  PIN:  Garde's port, unchanged: 12 blocks, 6 heads, MLP 1536, LayerScale, LayerNorm ε 1e-6,
//        exact GELU, manual softmax attention, no register tokens, a fixed 224 input (16×16
//        patches) with the position embedding pre-interpolated to [1, 257, 384] and the patch
//        Conv2d stored [O, kH, kW, I]. The forward runs in the loaded weights' dtype (F32 small,
//        F16 xsmall, int8 Linear xxsmall) and returns F32.
//

import Foundation
import MLX
import MLXNN

private func attention(_ x: MLXArray, q: Linear, k: Linear, v: Linear, proj: Linear, heads: Int, scale: Float) -> MLXArray {
    let (B, L) = (x.dim(0), x.dim(1))
    let qa = q(x).reshaped(B, L, heads, -1).transposed(0, 2, 1, 3)
    let ka = k(x).reshaped(B, L, heads, -1).transposed(0, 2, 1, 3)
    let va = v(x).reshaped(B, L, heads, -1).transposed(0, 2, 1, 3)
    let scores = softmax(matmul(qa, ka.transposed(0, 1, 3, 2)) * scale, axis: -1)
    let o = matmul(scores, va).transposed(0, 2, 1, 3).reshaped(B, L, -1)
    return proj(o)
}

final class Dinov2Attention: Module {
    let heads: Int
    let scale: Float
    @ModuleInfo(key: "q") var q: Linear
    @ModuleInfo(key: "k") var k: Linear
    @ModuleInfo(key: "v") var v: Linear
    @ModuleInfo(key: "proj") var proj: Linear

    init(dims: Int, heads: Int) {
        self.heads = heads
        self.scale = pow(Float(dims / heads), -0.5)
        self._q.wrappedValue = Linear(dims, dims, bias: true)
        self._k.wrappedValue = Linear(dims, dims, bias: true)
        self._v.wrappedValue = Linear(dims, dims, bias: true)
        self._proj.wrappedValue = Linear(dims, dims, bias: true)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { attention(x, q: q, k: k, v: v, proj: proj, heads: heads, scale: scale) }
}

final class Dinov2MLP: Module {
    @ModuleInfo(key: "fc1") var fc1: Linear
    @ModuleInfo(key: "fc2") var fc2: Linear

    init(dims: Int, hidden: Int) {
        self._fc1.wrappedValue = Linear(dims, hidden, bias: true)
        self._fc2.wrappedValue = Linear(hidden, dims, bias: true)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { fc2(gelu(fc1(x))) }   // exact GELU
}

final class Dinov2Block: Module {
    @ModuleInfo(key: "norm1") var norm1: LayerNorm
    @ModuleInfo(key: "attn") var attn: Dinov2Attention
    @ParameterInfo(key: "ls1") var ls1: MLXArray
    @ModuleInfo(key: "norm2") var norm2: LayerNorm
    @ModuleInfo(key: "mlp") var mlp: Dinov2MLP
    @ParameterInfo(key: "ls2") var ls2: MLXArray

    init(dims: Int, heads: Int, mlpHidden: Int, eps: Float) {
        self._norm1.wrappedValue = LayerNorm(dimensions: dims, eps: eps)
        self._attn.wrappedValue = Dinov2Attention(dims: dims, heads: heads)
        self._ls1.wrappedValue = MLXArray.ones([dims])
        self._norm2.wrappedValue = LayerNorm(dimensions: dims, eps: eps)
        self._mlp.wrappedValue = Dinov2MLP(dims: dims, hidden: mlpHidden)
        self._ls2.wrappedValue = MLXArray.ones([dims])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = x + ls1 * attn(norm1(x))
        return h + ls2 * mlp(norm2(h))
    }
}

public final class Dinov2ViT: Module {
    @ModuleInfo(key: "patch_embed") var patchEmbed: Conv2d
    @ParameterInfo(key: "cls_token") var clsToken: MLXArray
    @ParameterInfo(key: "pos_embed") var posEmbed: MLXArray
    let blocks: [Dinov2Block]
    @ModuleInfo(key: "norm") var norm: LayerNorm

    public init(hidden: Int = 384, layers: Int = 12, heads: Int = 6, patch: Int = 14, eps: Float = 1e-6) {
        self._patchEmbed.wrappedValue = Conv2d(inputChannels: 3, outputChannels: hidden, kernelSize: .init(patch), stride: .init(patch))
        self._clsToken.wrappedValue = MLXArray.zeros([1, 1, hidden])
        self._posEmbed.wrappedValue = MLXArray.zeros([1, 16 * 16 + 1, hidden])
        self.blocks = (0..<layers).map { _ in Dinov2Block(dims: hidden, heads: heads, mlpHidden: hidden * 4, eps: eps) }
        self._norm.wrappedValue = LayerNorm(dimensions: hidden, eps: eps)
        super.init()
    }

    /// The final-norm token sequence (B, 257, hidden) for NHWC ImageNet-normalized pixels.
    func tokens(_ pixels: MLXArray) -> MLXArray {
        let dt = clsToken.dtype
        let B = pixels.dim(0)
        var p = patchEmbed(pixels.asType(dt))
        p = p.flattened(start: 1, end: 2)
        let cls = broadcast(clsToken, to: [B, 1, clsToken.dim(2)])
        var x = concatenated([cls, p], axis: 1)
        x = x + posEmbed
        for blk in blocks { x = blk(x) }
        return norm(x)
    }

    /// The CLS embedding (B, hidden), F32.
    public func callAsFunction(_ pixels: MLXArray) -> MLXArray {
        tokens(pixels)[0..., 0..<1, 0...].squeezed(axis: 1).asType(.float32)
    }

    /// The patch tokens (B, 256, hidden), F32, CLS row excluded.
    public func patchTokens(_ pixels: MLXArray) -> MLXArray {
        tokens(pixels)[0..., 1..., 0...].asType(.float32)
    }

    public func loadWeights(url: URL) throws {
        let w = try loadArrays(url: url)
        try update(parameters: ModuleParameters.unflattened(w), verify: [.all])
        eval(self)
    }
}
