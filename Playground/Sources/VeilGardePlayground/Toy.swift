//
//  Toy.swift
//  VeilGardePlayground
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The training regime in miniature, on real code paths: a dataset of the final_mixed
//        sample (its tiles cut by the warp lens into Playground/.work), and a small store, a
//        seeded sample of the work area's feature store when this Mac has it. Without the T9 or
//        that store, seeded synthetic tiles and rows take their place, and the output says so.
//  PIN:  Writes only Playground/.work; reads final_mixed and the work area's store, never writes them.
//

import Foundation
import VeilGarde

enum Toy {
    static let dataset = Scratch.work.appendingPathComponent("toy/dataset.jsonl")
    static let store = Scratch.work.appendingPathComponent("store/shards", isDirectory: true)
    /// The work area's feature store (VEILGARDE_SEED_STORE names another), read, never written.
    static let seedStore = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VEILGARDE_SEED_STORE"]
        ?? WorkArea.resolve()?.shards.path ?? "store/shards", isDirectory: true)

    /// The toy dataset: the labeled sample, two of each class held out for validation. Returns
    /// what it is made of.
    static func writeDataset(_ sample: [PlaygroundImage]) throws -> String {
        try? FileManager.default.removeItem(at: dataset.deletingLastPathComponent())
        let labeled = sample.filter { $0.label != nil }
        if labeled.count >= 8 {
            var records: [ImageRecord] = []
            for label in [0, 1] {
                for (k, image) in labeled.filter({ $0.label == label }).enumerated() {
                    records.append(ImageRecord(path: image.url.path, label: label, stem: (image.name as NSString).deletingPathExtension,
                                               split: k < 2 ? .val : .train))
                }
            }
            try ImageManifest(records: records, root: dataset.deletingLastPathComponent()).write(to: dataset)
            return "\(records.count) final_mixed images (\(records.filter { $0.split == .train }.count) train, \(records.filter { $0.split == .val }.count) validation)"
        }
        // No T9: 120 synthetic images whose tiles are written straight into the cache.
        var rng = SplitMix64(seed: 5)
        let records = (0..<120).map { ImageRecord(path: "synthetic/\($0).png", label: $0 % 2, stem: String(format: "synthetic_%03d", $0), split: $0 % 5 == 0 ? .val : .train) }
        let manifest = ImageManifest(records: records, root: dataset.deletingLastPathComponent())
        try manifest.write(to: dataset)
        var images: [TileImage] = [], features: [Float] = [], texture: [Float] = []
        for r in records {
            images.append(TileImage(stem: r.stem, path: r.path, label: r.label, split: r.split!, pool: nil, tag: nil, rows: 4, cols: 4, start: texture.count, width: 128, height: 128))
            for _ in 0..<16 {
                var row = (0..<WarpFeatures.count).map { _ in Float(rng.unit()) }
                row[0] = Float(rng.unit()) * 0.6 + (r.label == 1 ? 0.3 : 0)
                features += row
                texture.append(Float(0.2 + rng.unit()))
            }
        }
        let cache = Scratch.work.appendingPathComponent("store/tiles/dataset", isDirectory: true)
        try? FileManager.default.removeItem(at: cache)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try TileShard(name: "tiles_0000", images: images, features: features, texture: texture).write(to: cache)
        return "120 synthetic images (the T9 is not mounted; their tiles are seeded, not measured)"
    }

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
                columns[.warp]!.append(Float(0.4 + (label == 1 ? 0.2 : 0) + 0.1 * Double(gauss())))
                columns[.sharp]! += [10, 10, 1]
                columns[.noiseprint]!.append(Float(label == 0 ? 0.6 : 0.3))
            }
        }
        try FeatureShard(name: "synthetic", rows: rows, columns: columns).write(to: store)
        return "\(rows.count) synthetic rows (no feature store on this Mac)"
    }
}
