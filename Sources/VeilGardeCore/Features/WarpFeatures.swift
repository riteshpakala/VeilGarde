//
//  WarpFeatures.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The 19 per-tile features the warp tile model reads, by name, in the order it was trained
//        on. Ten describe the round-trip residual (how fragile the tile is, how the residual's
//        texture and direction behave, how it relates to the mirrored tile and its neighbours'
//        seams); six describe the demosaic structure of the raw pixels; three are spectral.
//  PIN:  The order is the deployed model's (v2.5 optimal_8, 19 columns): FR, LV, CV, CM, CC, CR,
//        SH, SV, SH_S, SV_S, xcorr_RG, cfa_G, xcorr_BG, xcorr_RB, cfa_R, cfa_B, noise_ratio,
//        diag_axial, nyq_R. A model with more columns reads the 21-value directional signature
//        after these (DirectionalSignature); the 19-column model never pays for it.
//

/// One 32×32 tile, measured. Every value is the tile's own except CC/CR (its point-mirrored tile)
/// and the seams (its lower and right neighbours), which are why features are computed over the
/// whole image's grid rather than tile by tile.
public struct WarpFeatures: Sendable, Equatable, Codable {
    /// Fragility rate: (mean residual at warp strength 0.05 − at 0.025) / 0.025. A camera tile's
    /// residual grows faster under a stronger warp than a generated one's.
    public var fr: Float
    /// Local variance of the weak-warp residual over 2×2 windows, averaged.
    public var lv: Float
    /// Circular variance of the residual's gradient direction over 9×9 windows: 0 when the
    /// residual's edges agree in direction, 1 when they point every way.
    public var cv: Float
    /// Residual magnitude where its direction is coherent: mean(|R| · (1 − circular variance)).
    public var cm: Float
    /// Pearson correlation of the tile's residual with its point-mirrored tile's.
    public var cc: Float
    /// Ratio of the smaller to the larger residual spread across that mirrored pair.
    public var cr: Float
    /// Horizontal seam step: |mean of the bottom 4 rows − mean of the next tile's top 4 rows|.
    public var sh: Float
    /// Vertical seam step: the same across the right/left strips.
    public var sv: Float
    /// Horizontal seam spectrum: mean |Δ| of the first 8 rFFT magnitudes across that seam.
    public var shS: Float
    /// Vertical seam spectrum.
    public var svS: Float
    /// Pearson correlation of the red and green high-pass planes.
    public var xcorrRG: Float
    /// Bayer phase spread of green: (max − min) / mean of the four 2×2 phase variances.
    public var cfaG: Float
    /// Pearson correlation of the blue and green high-pass planes.
    public var xcorrBG: Float
    /// Pearson correlation of the red and blue high-pass planes.
    public var xcorrRB: Float
    /// Bayer phase spread of red.
    public var cfaR: Float
    /// Bayer phase spread of blue.
    public var cfaB: Float
    /// Noise ratio: std of the red high-pass over std of the green high-pass.
    public var noiseRatio: Float
    /// Diagonal over axial gradient energy on the raw green plane.
    public var diagAxial: Float
    /// Nyquist energy of the red high-pass: |mean(R_hp · (−1)^(i+j))|.
    public var nyqR: Float

    public static let count = 19
    public static let names = [
        "FR", "LV", "CV", "CM", "CC", "CR", "SH", "SV", "SH_S", "SV_S",
        "xcorr_RG", "cfa_G", "xcorr_BG", "xcorr_RB", "cfa_R", "cfa_B", "noise_ratio", "diag_axial", "nyq_R",
    ]

    /// The model's column order.
    public var asVector: [Float] {
        [fr, lv, cv, cm, cc, cr, sh, sv, shS, svS, xcorrRG, cfaG, xcorrBG, xcorrRB, cfaR, cfaB, noiseRatio, diagAxial, nyqR]
    }

    /// Reads the first 19 values of a model row (a wider row carries the directional signature after).
    public init(vector: [Float]) throws {
        guard vector.count >= Self.count else {
            throw VeilGardeFailure.data("a warp feature row has \(vector.count) values, not \(Self.count)")
        }
        fr = vector[0]; lv = vector[1]; cv = vector[2]; cm = vector[3]; cc = vector[4]; cr = vector[5]
        sh = vector[6]; sv = vector[7]; shS = vector[8]; svS = vector[9]
        xcorrRG = vector[10]; cfaG = vector[11]; xcorrBG = vector[12]; xcorrRB = vector[13]
        cfaR = vector[14]; cfaB = vector[15]; noiseRatio = vector[16]; diagAxial = vector[17]; nyqR = vector[18]
    }

    /// The name of column `index` of a model row, the directional signature included.
    public static func name(ofColumn index: Int) -> String {
        if index < count { return names[index] }
        let d = index - count
        return d < DirectionalSignature.names.count ? DirectionalSignature.names[d] : "f\(index)"
    }

    /// The columns of the named features, ascending (a column mask); an unknown or repeated name is refused.
    public static func columns(named wanted: [String]) throws -> [Int] {
        var out: [Int] = []
        for name in wanted {
            guard let column = names.firstIndex(of: name) else {
                throw VeilGardeFailure.usage("no warp feature is named \(name)", hint: "the 19 are \(names.joined(separator: ", "))")
            }
            guard !out.contains(column) else { throw VeilGardeFailure.usage("the warp feature \(name) is named twice") }
            out.append(column)
        }
        guard !out.isEmpty else { throw VeilGardeFailure.usage("a feature mask names at least one warp feature") }
        return out.sorted()
    }
}

/// The 21 columns a 40-column warp model reads after the 19: the residual energy of eight
/// directional probes (translate x and y, shear x and y, two diagonals, scale, rotate) at strengths
/// 0.025 and 0.05, then five log-ratios between them (v2.6, dormant with the shipped 19-column
/// model). Names are Garde's feature-dump spellings.
public enum DirectionalSignature {
    public static let count = 21
    public static let probes = ["tx", "ty", "shx", "shy", "dg1", "dg2", "scl", "rot"]
    public static let names: [String] = probes.map { "E_s025_\($0)" } + probes.map { "E_s05_\($0)" }
        + ["logtxty_s1", "logtxty_s2", "logaxdiag_s2", "logshear_s2", "ctrl_slope"]
}
