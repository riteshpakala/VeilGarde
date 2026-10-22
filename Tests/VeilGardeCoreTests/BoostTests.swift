//
//  BoostTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: GBDTModel against the shipped camera head: decoding then encoding writes the file's exact
//        bytes; the head is a from-scratch fit over the 393-column camera row; a fresh model encodes and
//        decodes to itself. (The trainer's parity with xgboost 3.2 is BoostTrainerTests'.)
//

import Foundation
import Testing
@testable import VeilGardeCore

@Suite("Boost codec and evaluator")
struct BoostTests {
    @Test("the shipped camera head round-trips to its exact bytes")
    func byteIdentity() throws {
        let data = try Data(contentsOf: Fixture.resource("camera.xgb.json"))
        let model = try GBDTModel.decode(xgboostJSON: data)
        let encoded = model.encodeXGBoostJSON()
        #expect(encoded == data, "\(encoded.count) bytes vs \(data.count)")
    }

    @Test("the shipped camera head is 500 trees of depth at most 5 over the 393-column camera row")
    func cameraShape() throws {
        let head = try GBDTModel.load(Fixture.resource("camera.xgb.json"))
        #expect(head.trees.count == 500)
        #expect(head.featureCount == CameraRow.width && CameraRow.width == 393)
        #expect((head.trees.map(\.depth).max() ?? 0) <= 5)
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
