//
//  Synthetic.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A throwaway work area for the engine's tests: a copy of the shipped bundle as the parent and
//        a seeded features-only store with every category the recipes read, so a full recipe trains
//        without the GPU or a single image.
//

import Foundation
import VeilGardeCore
@testable import VeilGardeTraining

struct SyntheticArea {
    let root: URL
    let area: WorkArea
    let parent: URL
    let store: URL

    static func make() throws -> SyntheticArea {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vg-engine-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // The parent: the shipped bundle's resources, copied.
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        try fm.copyItem(at: Fixture.resources, to: parent)
        let area = WorkArea(root: root.appendingPathComponent("area", isDirectory: true))
        let store = area.root.appendingPathComponent("store/shards", isDirectory: true)
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        try writeStore(store)
        return SyntheticArea(root: root, area: area, parent: parent, store: store)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    // MARK: The store

    static func writeStore(_ directory: URL) throws {
        var rng = SplitMix64(seed: 7)
        func gauss() -> Float {
            let u = max(1e-12, rng.unit()), v = rng.unit()
            return Float((-2 * log(u)).squareRoot() * cos(2 * .pi * v))
        }
        let sources = ["civitai", "commons_native", "wikimedia", "inat", "hf_faces", "openverse", "mj_v6"]
        let plan: [(category: String, label: Int, count: Int)] = [
            ("art", 1, 150), ("art", 0, 100), ("blur", 1, 100), ("blur", 0, 80), ("human", 1, 120), ("human", 0, 200),
            ("cgi", 1, 80), ("cgi", 0, 60), ("preview", 1, 60), ("preview", 0, 60), ("photo", 0, 220),
        ]
        let categoryIndex = ["art": 0, "blur": 1, "human": 2, "cgi": 3, "preview": 4, "photo": 5]
        for (shardName, newGen) in [("base_a", false), ("scrape_20260101", true)] {
            var rows: [FeatureRow] = []
            var columns: [FeatureColumn: [Float]] = Dictionary(uniqueKeysWithValues: FeatureColumn.allCases.map { ($0, [Float]()) })
            var serial = 0
            for p in plan where !newGen || p.label == 1 {
                let n = newGen ? p.count / 3 : p.count
                for _ in 0..<n {
                    serial += 1
                    let id = ContentHash.sha1Hex(Data("\(shardName)-\(serial)".utf8))
                    let golden = !newGen && p.category == "photo" && serial % 7 == 0
                    let path = golden && serial % 21 == 0 ? "/pools/bsky/\(serial).jpg" : "/pools/\(p.category)/\(serial).jpg"
                    rows.append(FeatureRow(id: id, path: path, label: p.label, category: p.category, source: sources[serial % sources.count],
                                           nsfw: serial % 53 == 0, golden: golden))
                    let c = categoryIndex[p.category]!
                    var norm = (0..<384).map { _ in gauss() }
                    if p.label == 1 { for j in (c * 10)..<(c * 10 + 10) { norm[j] += 1.6 } }
                    var fusion = (0..<384).map { _ in gauss() }
                    if p.label == 1 { for j in 0..<12 { fusion[j] += 1.0 } }
                    columns[.dinoNorm]! += norm
                    columns[.dinoFusion]! += fusion
                    let present: Float = p.label == 0 && serial % 3 == 0 ? 1 : 0
                    columns[.cap]! += [Float(rng.unit() * 60), 1, present, 2000, Float(rng.unit() * 10), 0.5, 0.5, 0.5, 0]
                }
            }
            try FeatureShard(name: shardName, rows: rows, columns: columns).write(to: directory)
        }
    }
}
