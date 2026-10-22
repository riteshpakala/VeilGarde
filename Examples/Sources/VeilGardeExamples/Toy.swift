//
//  Toy.swift
//  VeilGardeExamples
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The training regime in miniature, on real code paths: a small store, a seeded sample of the
//        work area's feature store when this Mac has it. Without that store, seeded synthetic rows
//        take its place, and the output says so.
//  PIN:  Writes only Examples/.work; reads final_mixed and the work area's store, never writes them.
//

import Foundation
import VeilGarde

enum Toy {
    static let store = Scratch.work.appendingPathComponent("store/shards", isDirectory: true)
    /// The work area's feature store (VEILGARDE_SEED_STORE names another), read, never written.
    static let seedStore = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VEILGARDE_SEED_STORE"]
        ?? WorkArea.resolve()?.shards.path ?? "store/shards", isDirectory: true)

    /// The toy store: per (category, label) group a seeded handful of the store's rows, or synthetic rows.
    static func writeStore() throws -> String {
        try? FileManager.default.removeItem(at: store)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let quota: [String: Int] = ["human/1": 120, "art/1": 120, "art/0": 80, "photo/0": 160, "wildlife/0": 80, "human/0": 80, "video/1": 60, "cgi/1": 40, "cgi/0": 40]
        if FileManager.default.fileExists(atPath: seedStore.path) {
            let all = try FeatureStore(directory: seedStore).select(columns: Set(FeatureColumn.allCases)) { !$0.nsfw }
            var picked: [Int] = []
            var groups: [String: [Int]] = [:]
            for i in 0..<all.count { groups["\(all.rows[i].category)/\(all.rows[i].label)", default: []].append(i) }
            for (key, members) in groups.sorted(by: { $0.key < $1.key }) {
                let ordered = members.sorted { StableSplit.unit(all.rows[$0].id, salt: "playground") < StableSplit.unit(all.rows[$1].id, salt: "playground") }
                let golden = ordered.filter { all.rows[$0].golden }
                picked += ordered.filter { !all.rows[$0].golden }.prefix(quota[key] ?? 0) + golden.prefix(key.hasSuffix("/0") ? 40 : 0)
            }
            picked.sort()
            let sample = all.subset(picked)
            try FeatureShard(name: "seed_sample", rows: sample.rows, columns: sample.columns).write(to: store)
            return "\(sample.count) rows of the work area's feature store (\(sample.rows.filter(\.golden).count) golden anchors), copied read-only"
        }
        var rng = SplitMix64(seed: 9)
        func gauss() -> Float { Float((-2 * log(max(1e-12, rng.unit()))).squareRoot() * cos(2 * .pi * rng.unit())) }
        var rows: [FeatureRow] = []
        var columns: [FeatureColumn: [Float]] = Dictionary(uniqueKeysWithValues: FeatureColumn.allCases.map { ($0, [Float]()) })
        let sources = ["civitai", "commons_native", "inat", "hf_faces", "wikimedia"]
        for (key, n) in quota.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: "/"), category = String(parts[0]), label = Int(parts[1])!
            for k in 0..<n {
                rows.append(FeatureRow(id: ContentHash.sha1Hex(Data("\(key)-\(k)".utf8)), path: "/synthetic/\(key)/\(k)", label: label, category: category,
                                       source: sources[k % sources.count], golden: label == 0 && k % 9 == 0))
                var norm = (0..<384).map { _ in gauss() }
                if label == 1 { for j in 0..<16 { norm[j + (category == "human" ? 0 : 20)] += 1.5 } }
                columns[.dinoNorm]! += norm
                columns[.dinoFusion]! += (0..<384).map { j in gauss() + (label == 1 && j < 8 ? 1 : 0) }
                columns[.cap]! += [Float(rng.unit() * 40), 1, 0, 2000, 5, 0.5, 0.5, 0.5, 0]
            }
        }
        try FeatureShard(name: "synthetic", rows: rows, columns: columns).write(to: store)
        return "\(rows.count) synthetic rows (no feature store on this Mac)"
    }
}
