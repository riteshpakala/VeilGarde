//
//  TorchBicubic.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: PyTorch's bicubic resize, bit for bit: F.interpolate(mode "bicubic", align_corners
//        False, antialias False) on a stack of square float32 planes. DINOv2 learned its
//        position embeddings on a 37×37 patch grid (518-pixel inputs); a 224-pixel input has
//        16×16 patches, so the grid is resized once at import and baked into the weights, as
//        Hugging Face's interpolate_pos_encoding does at every forward pass.
//  PIN:  ATen's CPU kernel (UpSampleKernel.cpp, HelperInterpCubic) in its float32 arithmetic:
//        scale = in / out; source x = scale·(i + 0.5) − 0.5 with no clamp; index = min(floor(x),
//        in − 1); t = clamp(x − index, 0, 1); weights from the cubic convolution with A = −0.75;
//        four taps at index − 1 … index + 2, each clamped to the edge; rows summed first, then
//        columns, each sum accumulated tap by tap. Clang contracts the source index, the weight
//        polynomials and every accumulation into fused multiply-adds, and so does this file
//        (addingProduct), which is what makes it exact rather than close: bicubic_fixture.json
//        and the shipped pos_embed are both reproduced with zero difference.
//

import Foundation

public enum TorchBicubic {
    static let A: Float = -0.75

    /// ((A + 2)·x − (A + 3))·x·x + 1, as clang fuses it.
    static func convolution1(_ x: Float) -> Float {
        let t = (-(A + 3)).addingProduct(A + 2, x)
        return Float(1).addingProduct(t * x, x)
    }

    /// ((A·x − 5A)·x + 8A)·x − 4A, as clang fuses it.
    static func convolution2(_ x: Float) -> Float {
        var t = (-(5 * A)).addingProduct(A, x)
        t = (8 * A).addingProduct(t, x)
        return (-(4 * A)).addingProduct(t, x)
    }

    /// The four tap indices and weights of each output position along one axis.
    public static func taps(input: Int, output: Int) -> [(index: [Int], weight: [Float])] {
        let scale = Float(input) / Float(output)
        return (0..<output).map { i in
            let real = Float(-0.5).addingProduct(scale, Float(i) + 0.5)
            let index = min(Int(real.rounded(.down)), input - 1)
            let t = min(max(real - Float(index), 0), 1)
            let weights = [convolution2(t + 1), convolution1(t), convolution1(1 - t), convolution2((1 - t) + 1)]
            let indices = (0..<4).map { j in max(min(index + j - 1, input - 1), 0) }
            return (indices, weights)
        }
    }

    /// `planes` square planes of side `input`, row-major one after another, resized to `output`.
    public static func resize(_ x: [Float], planes: Int, input: Int, output: Int) -> [Float] {
        precondition(x.count == planes * input * input, "resize: \(x.count) values are not \(planes) planes of \(input)×\(input)")
        let t = taps(input: input, output: output)
        var out = [Float](repeating: 0, count: planes * output * output)
        for c in 0..<planes {
            let base = c * input * input
            for oy in 0..<output {
                let (rows, wy) = t[oy]
                for ox in 0..<output {
                    let (cols, wx) = t[ox]
                    var outer: Float = 0
                    for a in 0..<4 {
                        let row = base + rows[a] * input
                        var inner = x[row + cols[0]] * wx[0]
                        for b in 1..<4 { inner = inner.addingProduct(x[row + cols[b]], wx[b]) }
                        outer = a == 0 ? inner * wy[0] : outer.addingProduct(inner, wy[a])
                    }
                    out[c * output * output + oy * output + ox] = outer
                }
            }
        }
        return out
    }
}
