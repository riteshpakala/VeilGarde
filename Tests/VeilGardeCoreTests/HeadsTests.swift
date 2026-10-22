//
//  HeadsTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The linear head and the stack combiner against float32 replicas of the reference's
//        arithmetic (written once from the Python reference), the shipped combiner as fitted on
//        2026-10-21 and keyed by member, a combiner file of another version refused, and the
//        trainer's file forms loading back as the runtime types.
//

import Foundation
import Testing
@testable import VeilGardeCore

@Suite("Heads and combiner")
struct HeadsTests {
    @Test("the art head's P(AI) matches the float32 replica")
    func linearHead() throws {
        let reference = try Fixture.json("head_reference.json")
        let head = try LinearHead.load(Fixture.resource("art_dinov2_v2.json"))
        #expect(head.coef.count == 384)
        #expect(head.normW == 360 && head.normH == 640)
        for case let c as [String: Any] in reference["cases"] as! [Any] {
            let p = head.pAI(floats(c["embedding"]))
            #expect(abs(p - float(c["p"])!) < 1e-6)
        }
    }

    @Test("every shipped head decodes with 384 coefficients", arguments: [
        "screenshot_dinov2_v1.10.json", "art_dinov2_v2.json", "blur_dinov2_v1.json", "human_dinov2_v4.json",
        "semtile_dinov2_v1.json", "preview_dinov2_v1.json",
    ])
    func shippedHeads(file: String) throws {
        let head = try LinearHead.load(Fixture.resource(file))
        #expect(head.coef.count == 384 && head.mean.count == 384 && head.scale.count == 384)
    }

    @Test("a HeadFile written by the trainer loads as the head it describes")
    func headFile() throws {
        let file = HeadFile(model: "test_dinov2", scalerMean: [0, 1], scalerScale: [1, 2], coef: [0.5, -0.25], intercept: 0.1)
        let head = try file.linearHead()
        let z: Float = 0.1 + 0.5 * 1 + ((3 - 1) / 2) * -0.25
        #expect(abs(head.pAI([1, 3]) - 1 / (1 + exp(-z))) < 1e-7)
        let text = String(decoding: try JSONCoding.prettyEncoder().encode(file), as: UTF8.self)
        #expect(text.contains("\"scaler_mean\"") && text.contains("\"fire_threshold\"") && text.contains("\"embed_source\""))
    }

    @Test("the shipped combiner is the 2026-10-21 fit, keyed by member: the camera anchor, art, blur and human as evidence")
    func combinerWeights() throws {
        let c = try StackCombiner.load(Fixture.resource("stack_combiner.json"))
        #expect(c.model == "stack_combiner" && c.version == 1)
        #expect(abs(c.w0 - -1.0216338510927914) < 1e-6)
        #expect(abs(c.anchor.w - 1.664112977699542) < 1e-6 && c.anchor.cap == 4 && c.anchor.gateCeiling == 0.75)
        #expect(c.evidenceMembers == ["art", "blur", "human"])
        #expect(abs(c.evidence[0].w - 0.15331665321009014) < 1e-6 && abs(c.evidence[1].w - 0.2197897549987958) < 1e-6 && abs(c.evidence[2].w - 0.2999066044320255) < 1e-6)
        #expect(c.rescue.w == 1 && c.evidenceCap == 2)
    }

    @Test("a combiner file of another version or model is refused")
    func otherVersionRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vg-combiner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("old.json")
        try Data(#"{"model": "stack_combiner", "version": 3, "w0": 0, "w_base": 1, "w_gen": [0, 0, 0], "w_rescue": 0.5, "cap_base": 4, "cap_head": 2, "gate_ceiling": 0.75}"#.utf8).write(to: old)
        #expect(throws: VeilGardeFailure.self) { try StackCombiner.load(old) }
        var other = try JSONSerialization.jsonObject(with: Data(contentsOf: Fixture.resource("stack_combiner.json"))) as! [String: Any]
        other["version"] = 2
        let next = dir.appendingPathComponent("next.json")
        try JSONSerialization.data(withJSONObject: other).write(to: next)
        #expect(throws: VeilGardeFailure.self) { try StackCombiner.load(next) }
    }

    @Test("pool and contribution match the float32 replica on the 19 tuples no art-pair moved")
    func combinerArithmetic() throws {
        let reference = try Fixture.json("combiner_reference.json")
        let c = try StackCombiner.load(Fixture.url("combiner_research.json"))
        var checked = 0
        for case let t as [String: Any] in reference["cases"] as! [Any] {
            let anchor = float(t["base"])!, evidence = floats(t["heads"])
            // The replica's art logit was min(art, art-pair); the cases where the pair moved it left with the art-pair head.
            if let pair = float(t["pair"]), c.lg(pair, c.evidenceCap) < c.lg(evidence[0], c.evidenceCap) { continue }
            checked += 1
            #expect(abs(c.pool(anchor: anchor, evidence: evidence) - float(t["pool"])!) < 1e-6)
            let expected = floats(t["contribution"])
            for k in 0..<3 { #expect(abs(c.contribution(k, anchor: anchor, evidence: evidence) - expected[k]) < 1e-6) }
        }
        #expect(checked == 19)
        // Neutral evidence at an even anchor: only w0 speaks.
        #expect(abs(c.pool(anchor: 0.5, evidence: [0.5, 0.5, 0.5]) - 1 / (1 + exp(0.6754975))) < 1e-6)
    }

    @Test("a CombinerFile loads as the combiner it describes")
    func combinerFile() throws {
        let file = CombinerFile(w0: -0.5, anchor: .init(w: 3), evidence: [.init(member: "art", w: 0), .init(member: "blur", w: 0.1), .init(member: "human", w: 0.2)],
                                rescue: .init(w: 0.5), note: "test")
        let c = try file.combiner()
        #expect(c.evidence.map(\.w) == [0, 0.1, 0.2] && c.evidenceMembers == ["art", "blur", "human"] && c.anchor.gateCeiling == 0.75 && c.version == 1)
        let text = String(decoding: try JSONCoding.prettyEncoder().encode(file), as: UTF8.self)
        #expect(text.contains("\"evidence_cap\"") && text.contains("\"gate_ceiling\"") && !text.contains("w_base"))
    }
}
