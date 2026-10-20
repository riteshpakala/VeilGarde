//
//  HeadsTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The linear head and the stack combiner against float32 replicas of Garde's arithmetic
//        (written once from the Python reference), the shipped combiner as Garde's weights without the
//        art-pair adjudicator, and the trainer's file forms loading back as the runtime types.
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
        "semtile_dinov2_v1.json", "cgi_dinov2_v1.json", "preview_dinov2_v1.json",
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

    @Test("the shipped combiner is Garde's weights without the art-pair adjudicator")
    func combinerWeights() throws {
        let c = try StackCombiner.load(Fixture.resource("stack_combiner_v2.json"))
        #expect(abs(c.w0 - -0.6754975) < 1e-6)
        #expect(abs(c.wBase - 3.8205218) < 1e-6)
        #expect(c.wGen.count == 3 && c.wGen[0] == 0 && c.wGen[1] == 0 && abs(c.wGen[2] - 0.19669296) < 1e-6)
        #expect(c.wRescue == 0.5 && c.wNp == 0.8 && c.capBase == 4 && c.capHead == 2 && c.gateCeiling == 0.75 && c.pairAdjudicates == false)
        // Garde's v1, the same weights adjudicated by the art-pair: an art-pair under the art head pulls the pool down; v2 ignores it.
        var v1 = try StackCombiner.load(Fixture.url("stack_combiner_v1.json"))
        #expect(v1.pairAdjudicates == true)
        let heads: [Float] = [0.9, 0.2, 0.1]
        #expect(v1.pool(base: 0.6, heads: heads, pairAI: 0.05) < v1.pool(base: 0.6, heads: heads))
        #expect(c.pool(base: 0.6, heads: heads, pairAI: 0.05) == c.pool(base: 0.6, heads: heads))
        v1.pairAdjudicates = false
        #expect(v1 == c)
    }

    @Test("pool and contribution match the float32 replica on 43 tuples")
    func combinerArithmetic() throws {
        let reference = try Fixture.json("combiner_reference.json")
        let c = try StackCombiner.load(Fixture.url("stack_combiner_v1.json"))
        for case let t as [String: Any] in reference["cases"] as! [Any] {
            let base = float(t["base"])!, heads = floats(t["heads"])
            let pair = float(t["pair"]), np = float(t["np"])
            #expect(abs(c.pool(base: base, heads: heads, pairAI: pair, np: np) - float(t["pool"])!) < 1e-6)
            let expected = floats(t["contribution"])
            for k in 0..<3 { #expect(abs(c.contribution(k, base: base, heads: heads, pairAI: pair) - expected[k]) < 1e-6) }
        }
        // Neutral heads at an even base: only w0 speaks.
        #expect(abs(c.pool(base: 0.5, heads: [0.5, 0.5, 0.5]) - 1 / (1 + exp(0.6754975))) < 1e-6)
    }

    @Test("a CombinerFile loads as the combiner it describes")
    func combinerFile() throws {
        let file = CombinerFile(w0: -0.5, wBase: 3, wGen: [0, 0.1, 0.2], wRescue: 0.5, wNp: 0.8, note: "test")
        let c = try file.combiner()
        #expect(c.wGen == [0, 0.1, 0.2] && c.wNp == 0.8 && c.pairAdjudicates == true && c.gateCeiling == 0.75)
    }
}
