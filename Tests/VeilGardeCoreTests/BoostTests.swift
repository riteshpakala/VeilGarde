//
//  BoostTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: GBDTModel against the shipped boosters: decoding then encoding writes each file's exact
//        bytes; predictions match xgboost 3.2's on seeded rows; the fusion head is its frozen
//        reference plus warm-start trees; a fresh model encodes and decodes to itself.
//

import Foundation
import Testing
@testable import VeilGardeCore

@Suite("Boost codec and evaluator")
struct BoostTests {
    @Test("each shipped booster round-trips to its exact bytes", arguments: ["warp_tile32.xgb.json", "fusion_head.xgb.json", "fusion_ref.xgb.json"])
    func byteIdentity(name: String) throws {
        let data = try Data(contentsOf: Fixture.resource(name))
        let model = try GBDTModel.decode(xgboostJSON: data)
        let encoded = model.encodeXGBoostJSON()
        #expect(encoded == data, "\(name): \(encoded.count) bytes vs \(data.count)")
    }

    @Test("the warp tile model is 200 trees of depth 8 over 19 features")
    func warpShape() throws {
        let model = try GBDTModel.load(Fixture.resource("warp_tile32.xgb.json"))
        #expect(model.trees.count == 200)
        #expect(model.featureCount == 19)
        #expect(model.trees.map(\.depth).max() == 8)
        #expect(model.baseScore == "[5.11784E-1]")
    }

    @Test("predictions match xgboost 3.2 on the warp and fusion boosters")
    func matchesXGBoost() throws {
        let reference = try Fixture.json("boost_reference.json")
        for (key, file) in [("warp", "warp_tile32.xgb.json"), ("fusion", "fusion_head.xgb.json")] {
            let model = try GBDTModel.load(Fixture.resource(file))
            let block = reference[key] as! [String: Any]
            let rows = (block["rows"] as! [[NSNumber]]).map { $0.map(\.floatValue) }
            let expected = floats(block["p"])
            let got = model.scoreBatch(rows)
            let worst = zip(got, expected).map { abs($0 - $1) }.max() ?? 0
            #expect(worst < 2e-6, "\(key): max |Δp| \(worst)")
        }
    }

    @Test("the fusion head is the frozen reference plus 40 warm-start trees")
    func fusionLineage() throws {
        let head = try GBDTModel.load(Fixture.resource("fusion_head.xgb.json"))
        let reference = try GBDTModel.load(Fixture.resource("fusion_ref.xgb.json"))
        #expect(head.trees.count == 940)
        #expect(reference.trees.count == 900)
        #expect(head.featureCount == 397)
        let shared = zip(head.trees.prefix(900), reference.trees).allSatisfy { a, b in
            a.leftChildren == b.leftChildren && a.splitIndices == b.splitIndices && a.splitConditions == b.splitConditions && a.baseWeights == b.baseWeights
        }
        #expect(shared)
    }

    @Test("a fresh model encodes, decodes and predicts as built")
    func freshModel() throws {
        // root: x0 < 0.5 → leaf −0.2, else x1 < 1 → leaf 0.1 | leaf 0.3
        let tree = GBDTModel.Tree(id: 0, leftChildren: [1, -1, 3, -1, -1], rightChildren: [2, -1, 4, -1, -1],
                                  parents: [GBDTModel.Tree.rootParent, 0, 0, 2, 2], splitIndices: [0, 0, 1, 0, 0],
                                  splitConditions: [0.5, -0.2, 1, 0.1, 0.3], baseWeights: [0.01, -0.2, 0.05, 0.1, 0.3],
                                  defaultLeft: [0, 0, 0, 0, 0], splitType: [0, 0, 0, 0, 0], lossChanges: [3, 0, 1.5, 0, 0],
                                  sumHessian: [10, 4, 6, 3, 3], numFeature: 2)
        let model = GBDTModel(trees: [tree], baseScoreProbability: 0.25, featureCount: 2)
        let decoded = try GBDTModel.decode(xgboostJSON: model.encodeXGBoostJSON())
        #expect(decoded.trees.count == 1)
        #expect(decoded.trees[0].splitConditions == tree.splitConditions)
        #expect(decoded.featureCount == 2)
        #expect(decoded.encodeXGBoostJSON() == model.encodeXGBoostJSON())
        let logit = Float(log(0.25 / 0.75))
        #expect(abs(decoded.margin([0.2, 0]) - (logit - 0.2)) < 1e-6)
        #expect(abs(decoded.margin([0.9, 2]) - (logit + 0.3)) < 1e-6)
        #expect(decoded.margin([0.9]) == decoded.margin([0.9, 0]))   // a missing column reads 0
    }
}
