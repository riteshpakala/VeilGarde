//
//  BoundedLogistic.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: An unregularized, weighted logistic fit with every evidence weight held ≥ 0 and the
//        intercept free: the stack combiner's fit, so no feature can invert (a head reading "real"
//        can never push toward "generated").
//  PIN:  the reference combiner's fit_constrained (atlas_combiner.py): −Σ s·[y log p + (1 − y) log(1 − p)], z clipped to ±30,
//        p clipped to [1e-9, 1 − 1e-9], start [0, 1, …, 1]; scipy L-BFGS-B with bounds there,
//        projected Newton with an active set here (seven unknowns, a dense Hessian). Both reach the
//        convex optimum to their tolerances (CombinerTests).
//

import Foundation

public enum BoundedLogistic {
    /// Fits θ = [intercept, w₁…w_m] on a row-major n × m matrix; w ≥ 0.
    public static func fit(f: [Double], y: [Double], m: Int, sampleWeight s: [Double], maxIterations: Int = 200) -> [Double] {
        let n = y.count
        var theta = [0.0] + [Double](repeating: 1, count: m)
        let D = m + 1
        func value(_ th: [Double]) -> Double {
            var total = 0.0
            for i in 0..<n {
                var z = th[0]
                for j in 0..<m { z += f[i * m + j] * th[j + 1] }
                z = min(max(z, -30), 30)
                let p = min(max(1 / (1 + exp(-z)), 1e-9), 1 - 1e-9)
                total -= s[i] * (y[i] * log(p) + (1 - y[i]) * log(1 - p))
            }
            return total
        }
        func project(_ th: [Double]) -> [Double] { [th[0]] + th[1...].map { max(0, $0) } }
        var current = value(theta)
        var row = [Double](repeating: 1, count: D)
        for _ in 0..<maxIterations {
            var g = [Double](repeating: 0, count: D)
            var H = [Double](repeating: 0, count: D * D)
            for i in 0..<n {
                var z = theta[0]
                for j in 0..<m { z += f[i * m + j] * theta[j + 1] }
                let p = 1 / (1 + exp(-min(max(z, -30), 30)))
                let r = s[i] * (p - y[i]), w = s[i] * p * (1 - p)
                for j in 0..<m { row[j + 1] = f[i * m + j] }
                for a in 0..<D {
                    g[a] += r * row[a]
                    for b in a..<D { H[a * D + b] += w * row[a] * row[b] }
                }
            }
            for a in 0..<D { for b in 0..<a { H[a * D + b] = H[b * D + a] } }
            // The free set: the intercept, every positive weight, and every zero weight the gradient pushes up.
            let free = (0..<D).filter { $0 == 0 || theta[$0] > 0 || g[$0] < 0 }
            let projected = (0..<D).map { free.contains($0) ? g[$0] : 0 }
            if (projected.map(abs).max() ?? 0) < 1e-8 { break }
            let k = free.count
            var Hf = [Double](repeating: 0, count: k * k)
            for (a, i) in free.enumerated() { for (b, j) in free.enumerated() { Hf[a * k + b] = H[i * D + j] } }
            for a in 0..<k { Hf[a * k + a] += 1e-10 }
            guard let step = Cholesky.solve(Hf, k, free.map { -g[$0] }) else { break }
            var direction = [Double](repeating: 0, count: D)
            for (a, i) in free.enumerated() { direction[i] = step[a] }
            var t = 1.0
            var moved = false
            for _ in 0..<50 {
                let candidate = project(zip(theta, direction).map { $0 + t * $1 })
                let v = value(candidate)
                if v < current - 1e-12 * max(1, abs(current)) {
                    theta = candidate
                    current = v
                    moved = true
                    break
                }
                t *= 0.5
            }
            if !moved { break }
        }
        return theta
    }
}
