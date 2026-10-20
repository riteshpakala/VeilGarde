//
//  MetricsTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: AUC (ties averaged, weighted or not) and log loss equal sklearn's on a tied score.
//

import Foundation
import Testing
@testable import VeilGardeTraining

@Suite("Metrics")
struct MetricsTests {
    @Test("AUC and log loss equal sklearn's, ties and weights included")
    func sklearn() throws {
        let fixture = try Fixture.json("boost_hist.json")
        let m = fixture["metrics"] as! [String: Any]
        let p = floats(m["p"]), w = floats(m["w"])
        let y = try Fixture.tensors("boost_hist.safetensors").float32("y_val")
        #expect(abs(Metrics.auc(p, y) - double(m["auc"])) < 1e-12)
        #expect(abs(Metrics.auc(p, y, weights: w) - double(m["auc_weighted"])) < 1e-9)
        #expect(abs(Metrics.logloss(p, y) - double(m["logloss"])) < 1e-9)
    }

    @Test("a missing class gives NaN; the operating point counts the band as inconclusive")
    func edges() {
        #expect(Metrics.auc([0.1, 0.2], [1, 1]).isNaN)
        let op = Metrics.operatingPoint([0.1, 0.55, 0.9, 0.7], [0, 0, 1, 0], threshold: 0.56, band: 0.04)
        #expect(op.inconclusiveRate == 0.25)
        #expect(op.realFalsePositiveRate == 1.0 / 3.0)
        #expect(op.generatedRecall == 1)
    }
}
