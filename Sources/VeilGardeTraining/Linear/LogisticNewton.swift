//
//  LogisticNewton.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: L2-regularized logistic regression solved exactly by Newton's method: every linear head
//        is fitted with it.
//  PIN:  sklearn's LogisticRegression objective, ½‖w‖² + C·Σ s_i·logloss_i with the intercept
//        unpenalized, s_i the sample weight times the class weight (`balanced` = n / (2·n_class)).
//        The problem is strictly convex, so Newton (the Hessian X̃ᵀ diag(C·s·p(1−p)) X̃ + I, solved
//        by Cholesky, Armijo backtracking until the decrement drops below what the objective can
//        resolve, full steps after) reaches the unique optimum sklearn's lbfgs approaches to its
//        tolerance; the two agree to that tolerance (LogisticTests). The Gram matrix is formed
//        with Accelerate's dsyrk in Double.
//

import Accelerate
import Foundation

public struct LogisticFit: Sendable, Equatable {
    public let coef: [Double]
    public let intercept: Double
    public let iterations: Int
    public let gradientNorm: Double

    /// P(y = 1) for one row.
    public func probability(_ row: ArraySlice<Double>) -> Double {
        var z = intercept
        for (j, v) in row.enumerated() { z += coef[j] * v }
        return 1 / (1 + exp(-z))
    }
}

public enum ClassWeight: String, Codable, Sendable {
    case none
    case balanced
}

public enum LogisticNewton {
    /// Fits on a row-major n × d Double matrix.
    public static func fit(x: [Double], y: [Double], d: Int, C: Double, classWeight: ClassWeight = .none,
                           sampleWeight: [Double]? = nil, maxIterations: Int = 100, tolerance: Double = 1e-9) -> LogisticFit {
        let n = y.count
        precondition(x.count == n * d, "x holds \(x.count) values for \(n) × \(d)")
        var s = sampleWeight ?? [Double](repeating: 1, count: n)
        if classWeight == .balanced {
            let positives = y.filter { $0 > 0.5 }.count, negatives = n - positives
            let wp = positives > 0 ? Double(n) / (2 * Double(positives)) : 0
            let wn = negatives > 0 ? Double(n) / (2 * Double(negatives)) : 0
            for i in 0..<n { s[i] *= y[i] > 0.5 ? wp : wn }
        }
        let D = d + 1
        // X̃ = [x | 1], row-major n × D.
        var xt = [Double](repeating: 1, count: n * D)
        for i in 0..<n { for j in 0..<d { xt[i * D + j] = x[i * d + j] } }

        var theta = [Double](repeating: 0, count: D)
        var margins = [Double](repeating: 0, count: n)
        func objective(_ th: [Double]) -> Double {
            var total = 0.0
            for j in 0..<d { total += 0.5 * th[j] * th[j] }
            cblas_dgemv(CblasRowMajor, CblasNoTrans, Int32(n), Int32(D), 1, xt, Int32(D), th, 1, 0, &margins, 1)
            for i in 0..<n {
                // log(1 + e^{−ỹz}) computed stably
                let m = y[i] > 0.5 ? -margins[i] : margins[i]
                total += C * s[i] * (m > 0 ? m + log1p(exp(-m)) : log1p(exp(m)))
            }
            return total
        }

        var iterations = 0
        var gradNorm = Double.infinity
        var current = objective(theta)
        var z = [Double](repeating: 0, count: n)
        for iteration in 0..<maxIterations {
            iterations = iteration + 1
            // z = X̃ θ
            cblas_dgemv(CblasRowMajor, CblasNoTrans, Int32(n), Int32(D), 1, xt, Int32(D), theta, 1, 0, &z, 1)
            var r = [Double](repeating: 0, count: n)        // C·s·(p − y)
            var h = [Double](repeating: 0, count: n)        // sqrt(C·s·p(1−p))
            for i in 0..<n {
                let p = 1 / (1 + exp(-z[i]))
                r[i] = C * s[i] * (p - y[i])
                h[i] = (C * s[i] * p * (1 - p)).squareRoot()
            }
            var g = [Double](repeating: 0, count: D)
            cblas_dgemv(CblasRowMajor, CblasTrans, Int32(n), Int32(D), 1, xt, Int32(D), r, 1, 0, &g, 1)
            for j in 0..<d { g[j] += theta[j] }
            gradNorm = g.map(abs).max() ?? 0
            if gradNorm < tolerance { break }
            // H = Aᵀ A + diag(1,…,1,0) with A = diag(h) X̃, accumulated over row chunks so a large
            // corpus never holds a second copy of X̃.
            var H = [Double](repeating: 0, count: D * D)
            let chunk = 8192
            var buffer = [Double](repeating: 0, count: min(chunk, n) * D)
            var start = 0
            while start < n {
                let rows = min(chunk, n - start)
                for i in 0..<rows {
                    let src = (start + i) * D, dst = i * D, hi = h[start + i]
                    for j in 0..<D { buffer[dst + j] = xt[src + j] * hi }
                }
                cblas_dsyrk(CblasRowMajor, CblasUpper, CblasTrans, Int32(D), Int32(rows), 1, buffer, Int32(D), 1, &H, Int32(D))
                start += rows
            }
            for i in 0..<D { for j in 0..<i { H[i * D + j] = H[j * D + i] } }
            for j in 0..<d { H[j * D + j] += 1 }
            H[d * D + d] += 1e-12
            guard let step = Cholesky.solve(H, D, g.map { -$0 }) else { break }
            let slope = zip(g, step).reduce(0) { $0 + $1.0 * $1.1 }        // −(Newton decrement)²
            // Near the optimum the objective cannot resolve the step any more (its change sits
            // below rounding), so a line search would crawl. Newton converges quadratically here:
            // take the full step.
            if -slope < 1e-12 * max(1, abs(current)) {
                theta = zip(theta, step).map { $0 + $1 }
                current = objective(theta)
                continue
            }
            // Armijo backtracking.
            var t = 1.0
            var accepted = false
            for _ in 0..<40 {
                let candidate = zip(theta, step).map { $0 + t * $1 }
                let value = objective(candidate)
                if value <= current + 1e-4 * t * slope {
                    theta = candidate
                    current = value
                    accepted = true
                    break
                }
                t *= 0.5
            }
            if !accepted { break }
        }
        return LogisticFit(coef: Array(theta[0..<d]), intercept: theta[d], iterations: iterations, gradientNorm: gradNorm)
    }
}

/// A dense symmetric positive-definite solve, for systems of a few hundred unknowns: the
/// Cholesky factor row by row with BLAS dot products, then two BLAS triangular solves.
enum Cholesky {
    static func solve(_ a: [Double], _ n: Int, _ b: [Double]) -> [Double]? {
        var L = [Double](repeating: 0, count: n * n)
        let ok: Bool = L.withUnsafeMutableBufferPointer { l in
            guard let base = l.baseAddress else { return false }
            for i in 0..<n {
                let rowI = base + i * n
                for j in 0...i {
                    let rowJ = base + j * n
                    let dot = j > 0 ? cblas_ddot(Int32(j), rowI, 1, rowJ, 1) : 0
                    let sum = a[i * n + j] - dot
                    if i == j {
                        guard sum > 0 else { return false }
                        rowI[i] = sum.squareRoot()
                    } else {
                        rowI[j] = sum / rowJ[j]
                    }
                }
            }
            return true
        }
        guard ok else { return nil }
        var x = b
        cblas_dtrsv(CblasRowMajor, CblasLower, CblasNoTrans, CblasNonUnit, Int32(n), L, Int32(n), &x, 1)
        cblas_dtrsv(CblasRowMajor, CblasLower, CblasTrans, CblasNonUnit, Int32(n), L, Int32(n), &x, 1)
        return x
    }
}
