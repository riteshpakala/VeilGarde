//
//  FragilityBandTests.swift
//  VeilWatermarkTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What the mark's optimiser stands on, checked before it is trusted: on the CPU, the objective's
//        ∂L/∂FR against finite differences of its loss; on the GPU, the forward read the optimiser uses
//        is NativePlane.fragility to the bit, autodiff's gradient of Σ c·FR is a one-sided finite
//        difference on the pixels that move it most (flat patches put |·|'s kink within float noise of
//        δ = 0), and that gradient vanishes more than 12 px inside a tile (the high-pass's mean is a border
//        term, and the warp reaches only a few pixels).
//

import Foundation
import MLX
import Testing
import VeilGardeCore
import VeilGardeLens
@testable import VeilWatermark

@Suite("The mark's objective")
struct FragilityObjectiveTests {
    @Test("∂L/∂FR is the derivative of the loss, tile by tile")
    func derivative() {
        var rng = SplitMix64(seed: 5)
        let levels: [Int8] = (0..<20).map { _ in rng.index(2) == 0 ? 1 : -1 }
        let objective = FragilityObjective(levels: levels, rows: 4, cols: 5, margin: 0.35, weight: 0.8, sharpness: 10)
        #expect(!objective.pairs.isEmpty)
        let fr = (0..<20).map { _ in Float(0.2 + rng.unit() * 3) }
        let e = objective.evaluate(fr)
        for t in 0..<20 {
            var up = fr, down = fr
            let h: Float = 1e-2
            up[t] += h
            down[t] -= h
            let numeric = (objective.evaluate(up).loss - objective.evaluate(down).loss) / (2 * h)
            #expect(abs(numeric - e.coefficients[t]) <= 2e-2 * max(0.05, abs(e.coefficients[t])), "tile \(t): \(numeric) against \(e.coefficients[t])")
        }
    }

    @Test("pairs are the differing-level neighbours, plus first; hopeless ones leave")
    func pairs() {
        // 1 × 2: a +1 tile east of a −1 tile.
        var objective = FragilityObjective(levels: [-1, 1], rows: 1, cols: 2, margin: 0.35, weight: 1, sharpness: 10)
        #expect(objective.pairs.count == 1 && objective.pairs[0].plus == 1 && objective.pairs[0].minus == 0)
        let held = objective.evaluate([0.5, 1.0])
        #expect(held.satisfied == 1 && held.active == 1)
        #expect(objective.evaluate([1.0, 0.5]).satisfied == 0)
        #expect(objective.dropHopeless([3.0, 0.2], factor: 3) == 1)
        #expect(objective.evaluate([3.0, 0.2]).active == 0)
    }
}

extension WatermarkMLXSuites {
    @Suite("The fragility band on the GPU", .serialized)
    struct FragilityBandGPU {
        /// crop_ben's top-left 64 × 64: four tiles, as a contiguous plane.
        static func plane() throws -> MLXArray {
            let full = try NativePlane(try ImageDecoding.cgImage(contentsOf: Fixture.crop("crop_ben.png")))
            let region = full.array[0..<64, 0..<64, 0...]
            return MLXArray(region.asArray(Float.self), [64, 64, 3])
        }

        static let coefficients: [Float] = [0.7, -1.3, 0.4, 1.1]

        static func objective(_ plane: MLXArray) -> Double {
            let fr = TileReads.fragility(plane, originX: 0, originY: 0, rows: 2, cols: 2)
            return zip(fr, coefficients).reduce(0) { $0 + Double($1.0 * $1.1) }
        }

        static func gradient(_ plane: MLXArray) -> [Float] {
            var g = [Float](repeating: 0, count: 64 * 64)
            FragilityGradient.accumulate(plane, originX: 0, originY: 0, rows: 2, cols: 2, coefficients: coefficients, width: 64, into: &g)
            return g
        }

        @Test("the forward read is NativePlane.fragility, at the origin and at a phase")
        func forwardRead() throws {
            let plane = try NativePlane(try ImageDecoding.cgImage(contentsOf: Fixture.crop("crop_ben.png")))
            for (ox, oy) in [(0, 0), (5, 11)] {
                let rows = (plane.height - oy) / 32, cols = (plane.width - ox) / 32
                #expect(TileReads.fragility(plane.array, originX: ox, originY: oy, rows: rows, cols: cols) == plane.fragility(originX: ox, originY: oy).values)
            }
        }

        /// FR is piecewise linear: |·| is its one kink. Where the image is flat, the round trip's differences are float
        /// noise (~1e-5), so a bundle of kinks sits within that of δ = 0 and no finite step sees a slope there: such a
        /// pixel's left and right differences disagree, and it is set aside. Everywhere the function is linear at the
        /// step's scale, autodiff must be its slope. (On a flat patch any move raises the residual: the optimiser's
        /// sign there is the noise's, and the bounds keep such pixels to one level.)
        @Test("autodiff is the slope of Σ c·FR wherever it is linear, on the sixteen pixels that move it most (median within 2.5%)")
        func gradientAgrees() throws {
            let plane = try Self.plane()
            let g = Self.gradient(plane)
            let top = g.indices.sorted { abs(g[$0]) > abs(g[$1]) }.prefix(16)
            #expect(abs(g[top.first!]) > 0)
            let h: Float = 0.002
            let base = Self.objective(plane)
            var errors: [Double] = [], kinked: [Int] = []
            for p in top {
                var bump = [Float](repeating: 0, count: 64 * 64)
                bump[p] = h
                let offset = MLXArray(bump, [64, 64, 1])
                let right = (Self.objective(plane + offset) - base) / Double(h)
                let left = (base - Self.objective(plane - offset)) / Double(h)
                if abs(right - left) > 0.1 * max(abs(right), abs(left)) {
                    kinked.append(p)
                    continue
                }
                errors.append(abs((right + left) / 2 - Double(g[p])) / abs(Double(g[p])))
            }
            #expect(kinked.count <= 6, "kinked at \(kinked.map { "(\($0 % 64), \($0 / 64))" })")
            // Kinks are dense even off the flat patches: hold the median tight and every pixel within twice that slack.
            let shown = errors.map { String(format: "%.3f", $0) }
            #expect(errors.count >= 10 && errors.sorted()[errors.count / 2] <= 0.025, "\(shown)")
            #expect(errors.allSatisfy { $0 <= 0.10 }, "\(shown)")
        }

        @Test("the gradient vanishes more than 12 px inside a tile")
        func band() throws {
            let g = Self.gradient(try Self.plane())
            let peak = g.map { abs($0) }.max() ?? 0
            #expect(peak > 0)
            var inside: Float = 0, border: Float = 0
            for y in 0..<64 {
                for x in 0..<64 {
                    let i = y % 32, j = x % 32
                    let depth = min(i, 31 - i, j, 31 - j)
                    if depth > 12 { inside = max(inside, abs(g[y * 64 + x])) } else { border = max(border, abs(g[y * 64 + x])) }
                }
            }
            #expect(border == peak)
            #expect(inside <= 1e-4 * peak, "inside \(inside) against a peak of \(peak)")
        }
    }
}
