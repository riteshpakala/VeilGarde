//
//  EvaluatorTests.swift
//  VeilGardeInferenceTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Frigate's XGBoostTreeModel (what the detector scores with, through TreeModelCache) and Core's
//        GBDTModel (what the trainer writes and evaluates) agree bit for bit on the shipped camera
//        head, missing values included.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeInference

@Suite("Tree evaluators")
struct EvaluatorTests {
    @Test("Frigate's evaluator and GBDTModel agree bit for bit on the shipped camera head")
    func evaluatorsAgree() throws {
        let url = Fixture.resource("camera.xgb.json")
        let frigate = try TreeModelCache.shared.model(url)
        let core = try GBDTModel.load(url)
        #expect(frigate.numFeatures == core.featureCount)
        var rng = SplitMix64(seed: 7)
        var rows = (0..<32).map { _ in (0..<core.featureCount).map { _ in Float(rng.unit() * 4 - 2) } }
        for i in stride(from: 0, to: rows.count, by: 4) { rows[i][384] = .nan; rows[i][0] = .nan }   // missing values go their default way
        #expect(frigate.predictBatch(rows) == core.scoreBatch(rows))
    }
}
