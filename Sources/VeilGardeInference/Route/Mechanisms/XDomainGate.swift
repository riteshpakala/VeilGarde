//
//  XDomainGate.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The x-domain trust gate (v0, flag-gated, off by default): on capture-absent content whose
//        mean semantic token lands nearest a measured meme-family centroid, the surfaced majority
//        is demoted to "inconclusive". Surfacing only: the semantic scores, the arbiters and the
//        weighted verdict are untouched.
//  PIN:  Garde's XDomainCentroids: standardize the mean token by (mu, sd), cosine to each of the 8
//        centroids, the nearest decides. Built from human-reviewed x_wild data where the semantic
//        majority measured chance (AUC 0.496) while the weighted verdict held 0.884 (the research record, quoted).
//

import Foundation

struct XDomainCentroids {
    let mu: [Float], sd: [Float]
    let centroids: [[Float]]
    let memeFlag: [Bool]

    static func load(_ url: URL) -> XDomainCentroids? {
        guard let data = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mu = j["mu"] as? [Double], let sd = j["sd"] as? [Double],
              let cs = j["centroids"] as? [[Double]], let mf = j["meme_flag"] as? [Bool] else { return nil }
        return XDomainCentroids(mu: mu.map(Float.init), sd: sd.map(Float.init), centroids: cs.map { $0.map(Float.init) }, memeFlag: mf)
    }

    /// True when the mean token's nearest centroid is meme-flagged.
    func isMemeFamily(_ meanTok: [Float]) -> Bool {
        guard meanTok.count == mu.count else { return false }
        var z = [Float](repeating: 0, count: meanTok.count)
        for j in 0..<meanTok.count { z[j] = (meanTok[j] - mu[j]) / sd[j] }
        let zn = sqrt(max(z.reduce(0) { $0 + $1 * $1 }, 1e-9))
        var best = -Float.infinity
        var bestIdx = -1
        for (i, c) in centroids.enumerated() {
            var dot: Float = 0, cn: Float = 0
            for j in 0..<c.count { dot += z[j] * c[j]; cn += c[j] * c[j] }
            let cos = dot / (zn * sqrt(max(cn, 1e-9)))
            if cos > best { best = cos; bestIdx = i }
        }
        return bestIdx >= 0 && memeFlag[bestIdx]
    }
}
