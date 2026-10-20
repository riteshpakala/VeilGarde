//
//  SplitTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The head split, draw for draw (source-disjoint with ≥ 4 sources, by id otherwise), the
//        manifest's stem partition, final_mixed's CSV, and the stratified folds.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeTraining

@Suite("Splits and manifests")
struct SplitTests {
    @Test("HeadSplit.heads equals atlas_heads_store.py's split")
    func raSplit() throws {
        let cases = try Fixture.json("head_split.json")["cases"] as! [[String: Any]]
        for c in cases {
            let split = HeadSplit.heads(ids: c["ids"] as! [String], sources: c["sources"] as! [String])
            #expect(split.isTest == (c["test"] as! [Bool]))
            #expect(split.basis.rawValue == c["basis"] as! String)
        }
    }

    @Test("a source split that leaves a class out falls back to the id split")
    func oneClassFallback() {
        // Every generated row comes from one source; that source is not among the test sources.
        let sources = ["civitai", "a", "b", "c", "d", "e", "f", "g"]
        var ids: [String] = [], src: [String] = [], labels: [Int] = []
        for k in 0..<400 { ids.append("id\(k)"); src.append(sources[k % sources.count]); labels.append(src.last == "civitai" ? 1 : 0) }
        let plain = HeadSplit.heads(ids: ids, sources: src)
        let checked = HeadSplit.heads(ids: ids, sources: src, labels: labels)
        let testHoldsBoth = Set(zip(labels, checked.isTest).filter { $0.1 }.map(\.0)).count == 2
        if Set(zip(labels, plain.isTest).filter { $0.1 }.map(\.0)).count == 2 {
            #expect(checked == plain)
        } else {
            #expect(checked.basis == .idsAfterOneClassSources)
            #expect(testHoldsBoth)
            #expect(checked.isTest == HeadSplit.byIDs(ids).isTest)
        }
    }

    @Test("a manifest partitions by stem, 70/15/15, and round-trips its bytes")
    func manifest() throws {
        let records = (0..<2000).map { ImageRecord(path: "x/\($0).jpg", label: $0 % 2, stem: "stem\($0 / 2)") }
        let m = ImageManifest(records: records, root: URL(fileURLWithPath: "/tmp")).withSplits()
        for k in stride(from: 0, to: 2000, by: 2) { #expect(m.records[k].split == m.records[k + 1].split, "a stem's variants share a partition") }
        let train = Double(m.records(in: .train).count) / 2000
        #expect(abs(train - 0.70) < 0.05)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vg-manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dataset.jsonl")
        try m.write(to: url)
        let back = try ImageManifest.load(url)
        #expect(back.records == m.records)
        #expect(back.sha256 == m.sha256)
        let sample = m.sample(perLabel: 10, seed: 1)
        #expect(sample.count == 20)
        #expect(sample == m.sample(perLabel: 10, seed: 1))
    }

    @Test("final_mixed's CSV converts, quotes and all")
    func finalMixed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vg-fm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let csv = "dest_name,class,source_pool,tag,scored_verdict,src_path\r\niphone_real_00000.jpeg,real,iphone,iphone,real,\"/a,b/IMG.jpeg\"\r\nagvr_ai_00001.png,generated,agvr_gen,fill,generated,/x.png\r\n"
        try csv.write(to: dir.appendingPathComponent("manifest.csv"), atomically: true, encoding: .utf8)
        let m = try ImageManifest.finalMixed(dir)
        #expect(m.records.map(\.path) == ["real/iphone_real_00000.jpeg", "generated/agvr_ai_00001.png"])
        #expect(m.records.map(\.label) == [0, 1])
        #expect(m.records.map(\.stem) == ["iphone_real_00000", "agvr_ai_00001"])
        #expect(m.records[1].pool == "agvr_gen")
    }

    @Test("hash folds are stratified and order-free")
    func folds() {
        let keys = (0..<100).map { "k\($0)" }, labels = (0..<100).map { $0 < 30 ? 1 : 0 }
        let fold = HashFolds.stratified(keys: keys, labels: labels, k: 5, salt: "t")
        for f in 0..<5 {
            #expect(keys.indices.filter { fold[$0] == f && labels[$0] == 1 }.count == 6)
            #expect(keys.indices.filter { fold[$0] == f && labels[$0] == 0 }.count == 14)
        }
        let reversed = HashFolds.stratified(keys: keys.reversed(), labels: labels.reversed(), k: 5, salt: "t")
        #expect(Array(reversed.reversed()) == fold)
    }
}
