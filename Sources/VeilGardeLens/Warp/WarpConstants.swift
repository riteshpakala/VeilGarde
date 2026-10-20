//
//  WarpConstants.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The warp lens's fixed probe: 32-px tiles, 16 homographies at two strengths, the residual's
//        high-pass, the feature kernels and strips, and the GPU batch size.
//  PIN:  Must match training (v2.4 optimal_6 onward): the high-pass is 9×9 at σ 1.5 (the one
//        parameter win of the v29 ablation), local variance 2×2, circular variance 9×9, seam
//        strips 4 px with 8 spectral bins. The strengths exist twice: in Float as the fragility
//        normaliser (Python's _S_HIGH/_S_LOW) and in Double for the corner displacements, so
//        `displacement · s · 32` is computed in float64 then cast, as numpy's `.astype(float32)`.
//

public enum WarpConstants {
    public static let tileSize = ScoringGeometry.tileSize
    public static let trials = 16
    public static let highPassKernel = 9
    public static let highPassSigma: Float = 1.5
    public static let localVarianceKernel = 2
    public static let circularVarianceKernel = 9
    public static let stripWidth = 4
    public static let seamBins = 8
    /// Tiles per MLX.eval: 256 tiles ≈ 150 MB of transient gather buffers; a 512-px image fits
    /// in one.
    public static let evalTileBudget = 256
    public static let lowStrength: Float = 0.025
    public static let highStrength: Float = 0.05
    static let lowStrengthD: Double = 0.025
    static let highStrengthD: Double = 0.05
}
