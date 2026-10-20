//
//  CLIPVision.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: CLIP ViT-B/32's vision tower and its projection in MLXNN: an image to the 512-value,
//        L2-normalized embedding the flywheel's category router compares with its prompt matrix
//        (what an acquired generated image depicts: a person, a scene, a blur, a render, art).
//  PIN:  openai/clip-vit-base-patch32 as Hugging Face's CLIPVisionModel runs it: a 32-px patch
//        Conv2d without bias (7×7 = 49 patches) plus a class token and 50 learned positions,
//        pre-LayerNorm ("pre_layrnorm", HF's spelling), 12 layers of 12-head attention and a
//        3072-wide MLP with quick-GELU (x·σ(1.702x)), LayerNorm ε 1e-5, the class token's
//        post-LayerNorm projected 768 → 512 without bias. Keys are HF's minus "vision_model.";
//        the patch kernel is stored [O, kH, kW, I] (`veilgarde weights import-clip`).
//

import CoreGraphics
import Foundation
import MLX
import MLXNN

final class CLIPAttention: Module {
    let heads: Int
    let scale: Float
    @ModuleInfo(key: "q_proj") var q: Linear
    @ModuleInfo(key: "k_proj") var k: Linear
    @ModuleInfo(key: "v_proj") var v: Linear
    @ModuleInfo(key: "out_proj") var out: Linear

    init(dims: Int, heads: Int) {
        self.heads = heads
        self.scale = pow(Float(dims / heads), -0.5)
        self._q.wrappedValue = Linear(dims, dims, bias: true)
        self._k.wrappedValue = Linear(dims, dims, bias: true)
        self._v.wrappedValue = Linear(dims, dims, bias: true)
        self._out.wrappedValue = Linear(dims, dims, bias: true)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))
        let qa = (q(x) * scale).reshaped(B, L, heads, -1).transposed(0, 2, 1, 3)
        let ka = k(x).reshaped(B, L, heads, -1).transposed(0, 2, 1, 3)
        let va = v(x).reshaped(B, L, heads, -1).transposed(0, 2, 1, 3)
        let weights = softmax(matmul(qa, ka.transposed(0, 1, 3, 2)), axis: -1)
        return out(matmul(weights, va).transposed(0, 2, 1, 3).reshaped(B, L, -1))
    }
}

final class CLIPMLP: Module {
    @ModuleInfo(key: "fc1") var fc1: Linear
    @ModuleInfo(key: "fc2") var fc2: Linear

    init(dims: Int, hidden: Int) {
        self._fc1.wrappedValue = Linear(dims, hidden, bias: true)
        self._fc2.wrappedValue = Linear(hidden, dims, bias: true)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = fc1(x)
        return fc2(h * sigmoid(1.702 * h))
    }
}

final class CLIPEncoderLayer: Module {
    @ModuleInfo(key: "self_attn") var attention: CLIPAttention
    @ModuleInfo(key: "layer_norm1") var norm1: LayerNorm
    @ModuleInfo(key: "mlp") var mlp: CLIPMLP
    @ModuleInfo(key: "layer_norm2") var norm2: LayerNorm

    init(dims: Int, heads: Int, hidden: Int, eps: Float) {
        self._attention.wrappedValue = CLIPAttention(dims: dims, heads: heads)
        self._norm1.wrappedValue = LayerNorm(dimensions: dims, eps: eps)
        self._mlp.wrappedValue = CLIPMLP(dims: dims, hidden: hidden)
        self._norm2.wrappedValue = LayerNorm(dimensions: dims, eps: eps)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = x + attention(norm1(x))
        return h + mlp(norm2(h))
    }
}

final class CLIPEncoder: Module {
    let layers: [CLIPEncoderLayer]

    init(count: Int, dims: Int, heads: Int, hidden: Int, eps: Float) {
        self.layers = (0..<count).map { _ in CLIPEncoderLayer(dims: dims, heads: heads, hidden: hidden, eps: eps) }
    }
}

final class CLIPEmbeddings: Module {
    @ModuleInfo(key: "patch_embedding") var patch: Conv2d
    @ParameterInfo(key: "class_embedding") var classEmbedding: MLXArray
    @ModuleInfo(key: "position_embedding") var position: Embedding

    init(dims: Int, patch: Int, positions: Int) {
        self._patch.wrappedValue = Conv2d(inputChannels: 3, outputChannels: dims, kernelSize: .init(patch), stride: .init(patch), bias: false)
        self._classEmbedding.wrappedValue = MLXArray.zeros([dims])
        self._position.wrappedValue = Embedding(embeddingCount: positions, dimensions: dims)
    }
}

public final class CLIPVision: Module {
    public static let embeddingWidth = 512
    public static let inputSize = 224

    @ModuleInfo(key: "embeddings") var embeddings: CLIPEmbeddings
    @ModuleInfo(key: "pre_layrnorm") var preNorm: LayerNorm
    @ModuleInfo(key: "encoder") var encoder: CLIPEncoder
    @ModuleInfo(key: "post_layernorm") var postNorm: LayerNorm
    @ModuleInfo(key: "visual_projection") var projection: Linear

    public init(dims: Int = 768, layers: Int = 12, heads: Int = 12, hidden: Int = 3072, patch: Int = 32, projectionDims: Int = 512, eps: Float = 1e-5) {
        let grid = Self.inputSize / patch
        self._embeddings.wrappedValue = CLIPEmbeddings(dims: dims, patch: patch, positions: grid * grid + 1)
        self._preNorm.wrappedValue = LayerNorm(dimensions: dims, eps: eps)
        self._encoder.wrappedValue = CLIPEncoder(count: layers, dims: dims, heads: heads, hidden: hidden, eps: eps)
        self._postNorm.wrappedValue = LayerNorm(dimensions: dims, eps: eps)
        self._projection.wrappedValue = Linear(dims, projectionDims, bias: false)
        super.init()
    }

    /// The L2-normalized image embeddings (B, 512), F32, for NHWC CLIP-normalized pixels.
    public func callAsFunction(_ pixels: MLXArray) -> MLXArray {
        let B = pixels.dim(0)
        var p = embeddings.patch(pixels.asType(.float32))
        p = p.flattened(start: 1, end: 2)
        let cls = broadcast(embeddings.classEmbedding.reshaped(1, 1, -1), to: [B, 1, p.dim(2)])
        var x = concatenated([cls, p], axis: 1) + embeddings.position.weight.expandedDimensions(axis: 0)
        x = preNorm(x)
        for layer in encoder.layers { x = layer(x) }
        let pooled = postNorm(x[0..., 0, 0...])
        let e = projection(pooled)
        return e / sqrt((e * e).sum(axis: -1, keepDims: true))
    }

    public func loadWeights(url: URL) throws {
        let w = try loadArrays(url: url)
        try update(parameters: ModuleParameters.unflattened(w), verify: [.all])
        eval(self)
    }
}

/// CLIPImageProcessor's input, the way the DINOv2 port draws its own: shortest side to 224 with
/// CoreGraphics' high-quality interpolation, centre crop 224, /255, CLIP's mean and std.
public enum CLIPPreprocess {
    public static let mean: [Float] = [0.48145466, 0.4578275, 0.40821073]
    public static let std: [Float] = [0.26862954, 0.26130258, 0.27577711]

    /// The resized, centre-cropped RGB bytes, row 0 the top, [224 · 224 · 3].
    public static func crop(_ cg: CGImage, size: Int = CLIPVision.inputSize) -> [UInt8] {
        let scale = Double(size) / Double(min(cg.width, cg.height))
        let sw = Double(cg.width) * scale, sh = Double(cg.height) * scale
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(data: &rgba, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return [UInt8](repeating: 0, count: size * size * 3)
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: -(sw - Double(size)) / 2, y: -(sh - Double(size)) / 2, width: sw, height: sh))
        var rgb = [UInt8](repeating: 0, count: size * size * 3)
        for i in 0..<(size * size) { rgb[i * 3] = rgba[i * 4]; rgb[i * 3 + 1] = rgba[i * 4 + 1]; rgb[i * 3 + 2] = rgba[i * 4 + 2] }
        return rgb
    }

    /// RGB bytes [n · 224 · 224 · 3] to the tower's (n, 224, 224, 3) input.
    public static func input(pixels: [UInt8], count n: Int, size: Int = CLIPVision.inputSize) -> MLXArray {
        var floats = [Float](repeating: 0, count: pixels.count)
        for i in 0..<pixels.count {
            let c = i % 3
            floats[i] = (Float(pixels[i]) / 255 - mean[c]) / std[c]
        }
        return MLXArray(floats, [n, size, size, 3])
    }

    public static func input(_ cg: CGImage) -> MLXArray { input(pixels: crop(cg), count: 1) }
}

/// The tower, loaded once from WeightLocator's clip_vit_b32_vision.safetensors.
public final class CLIPLens: @unchecked Sendable {
    public static let shared = CLIPLens()
    private let lock = NSLock()
    private var model: CLIPVision?

    public func tower() throws -> CLIPVision {
        lock.lock()
        defer { lock.unlock() }
        if let model { return model }
        let m = CLIPVision()
        try m.loadWeights(url: WeightLocator.shared.require(.clipVision))
        model = m
        return m
    }

    /// The image's 512-value normalized embedding.
    public static func embedding(_ cg: CGImage) throws -> [Float] {
        try shared.tower()(CLIPPreprocess.input(cg)).reshaped(-1).asArray(Float.self)
    }
}
