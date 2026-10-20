//
//  WeightedVerdict.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The warp lens's weighted score: Σ p·weight over the patch grid, then the hotspot blend
//        toward the mean of the confident patches. It is the warp-only verdict at 0.56 ± 0.04 and
//        the first column of the fusion vector.
//  PIN:  Garde's weightedVerdict, unchanged in arithmetic and loop order.
//

public enum WeightedVerdict {
    public static func score(patchGrid: [[Float]], weightMap: [[Float]], hotspot: HotspotRule) -> Float {
        var score: Float = 0
        let Pr = patchGrid.count, Pc = patchGrid.first?.count ?? 0
        for i in 0..<Pr { for j in 0..<Pc { score += patchGrid[i][j] * weightMap[i][j] } }
        guard hotspot.mode != .off else { return score }
        var extremes = [Float]()
        for i in 0..<Pr {
            for j in 0..<Pc {
                let p = patchGrid[i][j]
                if p > hotspot.threshold {
                    extremes.append(p)
                } else if hotspot.mode == .symmetric, p < 1 - hotspot.threshold {
                    // Symmetric: confident-real patches pull down, mirroring the confident-generated pull.
                    extremes.append(p)
                }
            }
        }
        if !extremes.isEmpty {
            let m = extremes.reduce(0, +) / Float(extremes.count)
            score = (1 - hotspot.blend) * score + hotspot.blend * m
        }
        return score
    }
}
