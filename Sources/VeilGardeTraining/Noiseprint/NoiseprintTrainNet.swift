//
//  NoiseprintTrainNet.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The noiseprint network in the form it trains in: a Bayar-constrained 5×5 first
//        convolution (its centre −1, its neighbours summing to 1, so every filter predicts a
//        pixel from its neighbours and passes on the error, suppressing content), then three
//        stride-2 convolutions, each conv followed by BatchNorm and ReLU, global average pooling
//        and a linear logit. About 33 thousand parameters. `folded` turns it into the four
//        biased convolutions NoiseprintNet runs; `unfolded` loads a folded file back for checks.
//  PIN:  the v202 reference's build_model: conv0 1→8 k5 p2 without bias, conv1 8→24, conv2 24→48, conv3
//        48→48 (k3 s2 p1), BatchNorm ε 1e-5 momentum 0.1, mean pool, Linear 48→1. The Bayar
//        constraint is a projection after every optimizer step (centre 0, divide by the sum
//        plus 1e-8, centre −1), not a reparameterisation. The fold is s = γ / √(σ² + ε),
//        W' = W·s, b' = β + (b − μ)·s, in double precision; the file's keys and shapes are
//        NoiseprintLens's: conv{0..3}.weight [O, kH, kW, I] and .bias [O], linear.weight [1, 48],
//        linear.bias [1].
//

import Foundation
import MLX
import MLXNN
import VeilGardeCore

public final class NoiseprintTrainNet: Module, UnaryLayer {
    @ModuleInfo(key: "conv0") var conv0: Conv2d
    @ModuleInfo(key: "bn0") var bn0: BatchNorm
    @ModuleInfo(key: "conv1") var conv1: Conv2d
    @ModuleInfo(key: "bn1") var bn1: BatchNorm
    @ModuleInfo(key: "conv2") var conv2: Conv2d
    @ModuleInfo(key: "bn2") var bn2: BatchNorm
    @ModuleInfo(key: "conv3") var conv3: Conv2d
    @ModuleInfo(key: "bn3") var bn3: BatchNorm
    @ModuleInfo(key: "linear") var linear: Linear

    public static let channels = [1, 8, 24, 48, 48]

    public override init() {
        let c = Self.channels
        _conv0.wrappedValue = Conv2d(inputChannels: c[0], outputChannels: c[1], kernelSize: 5, stride: 1, padding: 2, bias: false)
        _bn0.wrappedValue = BatchNorm(featureCount: c[1])
        _conv1.wrappedValue = Conv2d(inputChannels: c[1], outputChannels: c[2], kernelSize: 3, stride: 2, padding: 1)
        _bn1.wrappedValue = BatchNorm(featureCount: c[2])
        _conv2.wrappedValue = Conv2d(inputChannels: c[2], outputChannels: c[3], kernelSize: 3, stride: 2, padding: 1)
        _bn2.wrappedValue = BatchNorm(featureCount: c[3])
        _conv3.wrappedValue = Conv2d(inputChannels: c[3], outputChannels: c[4], kernelSize: 3, stride: 2, padding: 1)
        _bn3.wrappedValue = BatchNorm(featureCount: c[4])
        _linear.wrappedValue = Linear(c[4], 1)
        super.init()
    }

    /// Patches [n, 128, 128, 1] in [0, 1] → logits [n, 1] (P(camera) after a sigmoid).
    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = relu(bn0(conv0(x)))
        h = relu(bn1(conv1(h)))
        h = relu(bn2(conv2(h)))
        h = relu(bn3(conv3(h)))
        return linear(h.mean(axes: [1, 2]))
    }

    // MARK: The Bayar constraint

    /// Projects conv0 back onto the constraint: centre −1, the other taps of each filter summing to 1.
    public func projectBayar() {
        let w = conv0.weight
        let k = w.dim(1), centre = k / 2
        var mask = [Float](repeating: 0, count: k * k)
        mask[centre * k + centre] = 1
        let m = MLXArray(mask, [1, k, k, 1])
        let off = w * (1 - m)
        let projected = off / (off.sum(axes: [1, 2], keepDims: true) + 1e-8) - m
        conv0.update(parameters: ModuleParameters.unflattened(["weight": projected]))
    }

    // MARK: Folding

    /// Every parameter and running statistic by its flattened name, as host floats.
    func host() -> [String: (shape: [Int], values: [Double])] {
        var out: [String: (shape: [Int], values: [Double])] = [:]
        for (name, array) in parameters().flattened() { out[name] = (array.shape, array.asType(.float32).asArray(Float.self).map(Double.init)) }
        return out
    }

    /// The inference network's weights: each BatchNorm folded into the convolution before it.
    public func folded() throws -> [String: (shape: [Int], values: [Float])] {
        let p = host()
        func get(_ name: String) throws -> (shape: [Int], values: [Double]) {
            guard let v = p[name] else { throw VeilGardeFailure.internalError("the noiseprint net has no \(name)") }
            return v
        }
        var out: [String: (shape: [Int], values: [Float])] = [:]
        for i in 0..<4 {
            let w = try get("conv\(i).weight"), o = w.shape[0], per = w.values.count / o
            let b = p["conv\(i).bias"]?.values ?? [Double](repeating: 0, count: o)
            let gamma = try get("bn\(i).weight").values, beta = try get("bn\(i).bias").values
            let mean = try get("bn\(i).running_mean").values, variance = try get("bn\(i).running_var").values
            let eps = Double([bn0, bn1, bn2, bn3][i].eps)
            var weight = [Float](repeating: 0, count: w.values.count), bias = [Float](repeating: 0, count: o)
            for c in 0..<o {
                let s = gamma[c] / (variance[c] + eps).squareRoot()
                for k in 0..<per { weight[c * per + k] = Float(w.values[c * per + k] * s) }
                bias[c] = Float(beta[c] + (b[c] - mean[c]) * s)
            }
            out["conv\(i).weight"] = (w.shape, weight)
            out["conv\(i).bias"] = ([o], bias)
        }
        let lw = try get("linear.weight"), lb = try get("linear.bias")
        out["linear.weight"] = (lw.shape, lw.values.map(Float.init))
        out["linear.bias"] = (lb.shape, lb.values.map(Float.init))
        return out
    }

    /// Folded weights as the inference file (Python safetensors' layout, as the shipped net was exported).
    public static func file(_ weights: [String: (shape: [Int], values: [Float])]) throws -> Data {
        try SafetensorsWriter.encode(weights.map { SafetensorsWriter.Entry($0.key, shape: $0.value.shape, .float32($0.value.values)) }, layout: .python)
    }

    /// A trainable net that computes what a folded file computes: each convolution takes the
    /// folded weight, and each BatchNorm becomes the identity (μ 0, σ² 1 − ε, γ 1) carrying conv0's
    /// folded bias (conv0 has none of its own).
    public static func unfolded(_ weights: [String: MLXArray]) throws -> NoiseprintTrainNet {
        let net = NoiseprintTrainNet()
        var p: [String: MLXArray] = [:]
        for i in 0..<4 {
            guard let w = weights["conv\(i).weight"], let b = weights["conv\(i).bias"] else { throw VeilGardeFailure.data("no conv\(i).weight/bias") }
            let o = w.dim(0), eps = [net.bn0, net.bn1, net.bn2, net.bn3][i].eps
            p["conv\(i).weight"] = w.asType(.float32)
            if i == 0 { p["bn0.bias"] = b.asType(.float32) } else { p["conv\(i).bias"] = b.asType(.float32); p["bn\(i).bias"] = MLXArray.zeros([o]) }
            p["bn\(i).weight"] = MLXArray.ones([o])
            p["bn\(i).running_mean"] = MLXArray.zeros([o])
            p["bn\(i).running_var"] = MLXArray.ones([o]) - eps
        }
        guard let lw = weights["linear.weight"], let lb = weights["linear.bias"] else { throw VeilGardeFailure.data("no linear.weight/bias") }
        p["linear.weight"] = lw.asType(.float32)
        p["linear.bias"] = lb.asType(.float32)
        try net.update(parameters: ModuleParameters.unflattened(p), verify: [.all])
        net.train(false)
        eval(net)
        return net
    }
}
