//
//  SplitTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The head split, draw for draw (source-disjoint with ≥ 4 sources, by id otherwise).
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeTraining

@Suite("Splits")
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
}
