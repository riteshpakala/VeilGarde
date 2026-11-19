//
//  ScaleSpace.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The lightness of a picture at every scale, and the colour it is sampled from: per octave,
//        s + 3 Gaussian images and their s + 2 differences (DoG), plus the R, G, B planes halved once
//        per octave. Anchors are the DoG's extrema; their neighbourhoods are cut from the colour planes.
//  PIN:  s = 3, σ0 = 1.6, the input assumed blurred 0.5 (no doubling); octave o + 1 starts from octave
//        o's image at 2σ0, every second pixel. Octaves while the short side stays ≥ 32 px, at most 6.
//        Blurs are separable vImage convolutions, kernel radius ⌈3σ⌉, edges extended. The colour
//        planes are blurred σ 1 before each halving and not otherwise, so each octave keeps the
//        texture the warp residual reads.
//  ROBUSTNESS: Class I · Resizing, Crop — an extremum found at σ in the picture is found at kσ in a
//        copy resized k×, and a crop keeps every extremum whose neighbourhood it holds.
//

import Accelerate
import Foundation

/// One float image, row-major.
struct Plane: Sendable {
    var width: Int
    var height: Int
    var values: [Float]

    @inline(__always) func at(_ x: Int, _ y: Int) -> Float {
        values[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
    }

    /// Bilinear, edges extended.
    @inline(__always) func sample(_ x: Float, _ y: Float) -> Float {
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let ax = x - fx, ay = y - fy
        let x0 = Int(fx), y0 = Int(fy)
        let top = at(x0, y0) * (1 - ax) + at(x0 + 1, y0) * ax
        let bottom = at(x0, y0 + 1) * (1 - ax) + at(x0 + 1, y0 + 1) * ax
        return top * (1 - ay) + bottom * ay
    }

    /// Every second pixel, starting at (0, 0).
    func halved() -> Plane {
        let w = max(1, width / 2), h = max(1, height / 2)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { out[y * w + x] = values[(2 * y) * width + 2 * x] }
        }
        return Plane(width: w, height: h, values: out)
    }

    func blurred(_ sigma: Float) -> Plane {
        guard sigma > 0.05, width > 1, height > 1 else { return self }
        let radius = max(1, Int((3 * sigma).rounded(.up)))
        var kernel = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let sum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / sum }
        var source = values
        var middle = [Float](repeating: 0, count: values.count)
        var out = [Float](repeating: 0, count: values.count)
        let w = vImagePixelCount(width), h = vImagePixelCount(height), rowBytes = width * MemoryLayout<Float>.stride
        let taps = UInt32(kernel.count)
        source.withUnsafeMutableBufferPointer { s in
            middle.withUnsafeMutableBufferPointer { m in
                out.withUnsafeMutableBufferPointer { o in
                    kernel.withUnsafeBufferPointer { k in
                        var sb = vImage_Buffer(data: s.baseAddress, height: h, width: w, rowBytes: rowBytes)
                        var mb = vImage_Buffer(data: m.baseAddress, height: h, width: w, rowBytes: rowBytes)
                        var ob = vImage_Buffer(data: o.baseAddress, height: h, width: w, rowBytes: rowBytes)
                        _ = vImageConvolve_PlanarF(&sb, &mb, nil, 0, 0, k.baseAddress!, 1, taps, 0, vImage_Flags(kvImageEdgeExtend))
                        _ = vImageConvolve_PlanarF(&mb, &ob, nil, 0, 0, k.baseAddress!, taps, 1, 0, vImage_Flags(kvImageEdgeExtend))
                    }
                }
            }
        }
        return Plane(width: width, height: height, values: out)
    }
}

struct ScaleSpace: Sendable {
    static let layers = 3
    static let sigma0: Float = 1.6
    static let assumedBlur: Float = 0.5
    static let maxOctaves = 6
    static let minimumSide = 32

    /// gaussians[o][i]: octave o at σ0 · 2^(i/s), in octave pixels.
    let gaussians: [[Plane]]
    /// dogs[o][i] = gaussians[o][i + 1] − gaussians[o][i].
    let dogs: [[Plane]]
    /// colour[o]: R, G, B at octave o's resolution.
    let colour: [[Plane]]

    init(_ image: SealImage) {
        let s = Self.layers
        let k = Float(pow(2.0, 1.0 / Double(s)))
        var octaves = 1
        var side = min(image.width, image.height)
        while octaves < Self.maxOctaves, side / 2 >= Self.minimumSide {
            side /= 2
            octaves += 1
        }
        // The blur each layer adds to the one before it.
        var steps: [Float] = [0]
        for i in 1..<(s + 3) {
            let previous = Self.sigma0 * pow(k, Float(i - 1)), total = previous * k
            steps.append((total * total - previous * previous).squareRoot())
        }
        var gaussians: [[Plane]] = []
        var dogs: [[Plane]] = []
        var base = Plane(width: image.width, height: image.height, values: image.lightness)
            .blurred((Self.sigma0 * Self.sigma0 - Self.assumedBlur * Self.assumedBlur).squareRoot())
        for o in 0..<octaves {
            if o > 0 { base = gaussians[o - 1][s].halved() }
            var level = [base]
            for i in 1..<(s + 3) { level.append(level[i - 1].blurred(steps[i])) }
            var differences: [Plane] = []
            for i in 0..<(s + 2) {
                let a = level[i].values, b = level[i + 1].values
                var d = [Float](repeating: 0, count: a.count)
                vDSP_vsub(a, 1, b, 1, &d, 1, vDSP_Length(a.count))
                differences.append(Plane(width: base.width, height: base.height, values: d))
            }
            gaussians.append(level)
            dogs.append(differences)
        }
        var colour: [[Plane]] = [[
            Plane(width: image.width, height: image.height, values: image.red),
            Plane(width: image.width, height: image.height, values: image.green),
            Plane(width: image.width, height: image.height, values: image.blue),
        ]]
        for o in 1..<max(1, octaves) {
            colour.append(colour[o - 1].map { $0.blurred(1).halved() })
        }
        self.gaussians = gaussians
        self.dogs = dogs
        self.colour = colour
    }
}
