//
//  DerivationTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A derived bundle: the noiseprint's key leaves the combiner and the edit is recorded, a set
//        weight takes, every other artifact stays the parent's bytes, an edit outside the whitelist
//        is refused, and a variant can be derived from a variant.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeTraining

@Suite("Bundle derivation")
struct DerivationTests {
    @Test("the noiseprint's key leaves, a weight is set, the rest stays the parent's, and the record says so")
    func derive() throws {
        let s = try SyntheticArea.make(images: 40)
        defer { s.remove() }
        let parent = try ModelBundle.load(s.parent)
        let v = try BundleDerivation.derive(id: "study-np", in: s.area, from: parent, edits: [try CombinerEdit.parse("combiner.w_np=null")], note: "the noiseprint not run")
        let combiner = try StackCombiner.load(try #require(v.url(.combiner)))
        let original = try StackCombiner.load(try #require(parent.url(.combiner)))
        #expect(combiner.wNp == nil && original.wNp != nil)
        #expect(combiner.w0 == original.w0 && combiner.wBase == original.wBase && combiner.wGen == original.wGen && combiner.wRescue == original.wRescue)
        let entry = try #require(v.manifest.artifact(.combiner))
        #expect(entry.source == "research: study-np" && entry.parent == parent.sha256(.combiner))
        #expect(v.manifest.history.count == 2 && v.manifest.history.last?.note?.contains("measurement only") == true)
        for artifact in v.manifest.artifacts where artifact.role != .combiner { #expect(artifact.sha256 == parent.manifest.artifact(slot: artifact.slot)?.sha256) }
        let record = try JSONCoding.read(DerivationRecord.self, from: v.root.appendingPathComponent("derive.json"))
        #expect(record.edits == ["combiner.w_np=null"] && record.parentCombinerSHA256 == parent.sha256(.combiner))
        try v.verify()

        let chained = try BundleDerivation.derive(id: "study-np-rescue", in: s.area, from: v.bundle,
                                                  edits: [try CombinerEdit.parse("combiner.w_rescue=0"), try CombinerEdit.parse("combiner.w_gen[2]=0")], note: "chained")
        let c2 = try StackCombiner.load(try #require(chained.url(.combiner)))
        #expect(c2.wRescue == 0 && c2.wGen[2] == 0 && c2.wNp == nil)
        #expect(try CombinerEdit.parse("combiner.w_np=0") == .set(field: "w_np", index: nil, value: 0))
        for bad in ["combiner.w_base=0", "combiner.w_gen[3]=0", "combiner.w_np=-1", "fusion.trees=3", "combiner.w_rescue[0]=1", "combiner.w_gen=1"] {
            #expect(throws: VeilGardeFailure.self, "\(bad)") { try CombinerEdit.parse(bad) }
        }
        #expect(throws: VeilGardeFailure.self) { try BundleDerivation.derive(id: "study-np", in: s.area, from: parent, edits: [.removeNoiseprint], note: "again") }
    }
}
