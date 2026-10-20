//
//  WeightMap.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: How much each patch counts in the weighted verdict: a Gaussian around the texture
//        centroid (the subject), times a texture weight (flat sky counts little), times a
//        confidence boost (decisive patches count more), normalized to sum to 1.
//  PIN:  Garde's buildWeightMap (Python _build_weight_map), unchanged in arithmetic and loop order:
//        tw = min-max normalized texture; σ = max(rows, cols) / centerSharpness;
//        weight = exp(−d²/2σ²) · (bias + (1 − bias)·tw^power) · (1 + 2|p − 0.5|).
//

import Foundation

public struct WeightMapParameters: Sendable, Equatable, Codable {
    public var centerSharpness: Float
    public var texturePower: Float
    public var textureBias: Float
    public var saliencyCenter: Bool

    public init(centerSharpness: Float = 8.0, texturePower: Float = 3.0, textureBias: Float = 0.2, saliencyCenter: Bool = true) {
        self.centerSharpness = centerSharpness
        self.texturePower = texturePower
        self.textureBias = textureBias
        self.saliencyCenter = saliencyCenter
    }
}

public enum WeightMap {
    public static func build(patchGrid: [[Float]], texWeights: [[Float]], parameters: WeightMapParameters) -> [[Float]] {
        let Pr = patchGrid.count, Pc = patchGrid.first?.count ?? 0
        let flat = texWeights.flatMap { $0 }
        let tMin = flat.min() ?? 0, tMax = flat.max() ?? 1
        var tw = [[Float]](repeating: [Float](repeating: 0, count: Pc), count: Pr)
        for i in 0..<Pr { for j in 0..<Pc { tw[i][j] = (texWeights[i][j] - tMin) / (tMax - tMin + 1e-8) } }

        var cy: Float, cx: Float
        if parameters.saliencyCenter {
            var sumW: Float = 0, sumY: Float = 0, sumX: Float = 0
            for i in 0..<Pr { for j in 0..<Pc { sumY += Float(i) * tw[i][j]; sumX += Float(j) * tw[i][j]; sumW += tw[i][j] } }
            cy = sumY / (sumW + 1e-8); cx = sumX / (sumW + 1e-8)
        } else {
            cy = Float(Pr) / 2; cx = Float(Pc) / 2
        }

        let sigma = Float(max(Pr, Pc)) / parameters.centerSharpness
        var combined = [[Float]](repeating: [Float](repeating: 0, count: Pc), count: Pr)
        var total: Float = 0
        for i in 0..<Pr {
            for j in 0..<Pc {
                let dx = Float(j) - cx, dy = Float(i) - cy
                let cw = Foundation.exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
                let texW = parameters.textureBias + (1 - parameters.textureBias) * pow(tw[i][j], parameters.texturePower)
                let conf = abs(patchGrid[i][j] - 0.5)
                let boost = 1.0 + 2.0 * conf
                combined[i][j] = cw * texW * boost
                total += combined[i][j]
            }
        }
        for i in 0..<Pr { for j in 0..<Pc { combined[i][j] /= max(total, 1e-12) } }
        return combined
    }
}
