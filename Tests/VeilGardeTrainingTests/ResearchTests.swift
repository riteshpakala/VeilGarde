//
//  ResearchTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The pruning study's arithmetic and its whole run. A paired comparison's AUC is Metrics'
//        AUC, identical scorings differ by exactly nothing, a better scoring's interval sits above
//        zero, and a seed gives the same interval twice. The Platt layer's call is a cut on the raw
//        tile vote for every vote a 256-tile grid can cast. On a synthetic work area whose only
//        label signal is FR, the study finds what it should: FR and its group cost AUC, no other
//        feature costs a tenth as much, alone or together, and every part reports its rows.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeTraining

@Suite("Research: the pruning study")
struct ResearchTests {
    static func noise(_ n: Int, seed: UInt64) -> [Float] {
        var rng = SplitMix64(seed: seed)
        return (0..<n).map { _ in Float(rng.unit()) }
    }

    @Test("a paired comparison: Metrics' AUC, zero for identical scorings, an interval above zero for a better one, the same twice")
    func paired() {
        let n = 400
        let labels = (0..<n).map { Float($0 % 2) }
        let ref = Self.noise(n, seed: 1).map { ($0 * 8).rounded() / 8 }          // ties
        #expect(abs((RankedScores(ref, labels).auc(nil) ?? 0) - Metrics.auc(ref, labels)) < 1e-12)
        let same = PairedComparison.measure(reference: ref, variant: ref, labels: labels, resamples: 200, seed: 0, call: { $0 > 0.5 ? "g" : "r" })
        #expect(same.delta == 0 && same.low == 0 && same.high == 0 && same.changedCalls == 0 && same.spansZero)
        let better = zip(Self.noise(n, seed: 2), labels).map { $0 * 0.6 + $1 * 0.4 }
        let c = PairedComparison.measure(reference: ref, variant: better, labels: labels, resamples: 200, seed: 0, call: { $0 > 0.5 ? "g" : "r" })
        #expect(c.delta > 0.2 && c.low > 0 && !c.spansZero && c.low <= c.delta && c.delta <= c.high)
        #expect(c == PairedComparison.measure(reference: ref, variant: better, labels: labels, resamples: 200, seed: 0, call: { $0 > 0.5 ? "g" : "r" }))
    }

    @Test("Garde's Platt contract is two cuts on the raw tile vote, the shipped ones, for every vote a 256-tile grid can cast")
    func calibration() throws {
        let sha = "516119c92d364dda3dba41dcfc42e06edf0f42e45efd3b54c44ab620f7eefe3d"
        let platt = try SensorCalibrationContract(sensorVariant: "warp19", sensorModelSHA256: sha, transform: .platt,
                                                  plattPayload: SensorPlattPayload(coef: 0.48908749922126266, intercept: -0.09094760943132153),
                                                  decisionThreshold: Float(0.6298664647384551), uncertainBand: 0.04)
        let data = try Data(contentsOf: Fixture.resources.appendingPathComponent("warp_sensor_calibration.json"))
        let shipped = try SensorCalibrationContract.decode(data, expectedModelSHA256: sha, expectedSensorVariant: "warp19")
        let votes = (0...256).map { Float($0) / 256 }
        let e = PruningStudy.equivalence(platt, votes: votes)
        #expect(e.agreeing == e.images && e.images == 257)
        #expect(e.rawReal < e.rawThreshold && e.rawThreshold < e.rawGenerated)
        #expect(abs(e.rawThreshold - 0.781) < 0.001, "T 0.6299 is a vote of 78.1%")
        #expect(shipped.transform == .cuts && shipped.cuts == SensorCuts(realAtOrBelow: e.rawReal, generatedAtOrAbove: e.rawGenerated))
        #expect(votes.allSatisfy { shipped.prediction(for: shipped.calibratedProbability($0)) == platt.prediction(for: platt.calibratedProbability($0)) })
        #expect(PruningStudy.equivalence(shipped, votes: votes).agreeing == 257)
    }

    @Test("on a synthetic area the study finds FR, and every part reports its rows")
    func study() throws {
        let synthetic = try SyntheticArea.make(images: 400)
        defer { synthetic.remove() }
        var s = PruningSettings()
        s.resamples = 60
        s.warpParams = BoostParams(trees: 30, maxDepth: 3, eta: 0.3, subsample: 0.8, colsampleByTree: 0.8, seed: 0)
        s.warpStages = [5, 15]
        s.warpDepths = [2]
        s.fusionTrees = 10
        s.fusionStages = [5]
        s.fusionDepths = [2]
        s.shippedFusionStages = [100]
        s.seedControls = [1]
        let bundle = try ModelBundle.load(synthetic.parent)
        let inputs = PruningStudy.Inputs(tiles: synthetic.area.root.appendingPathComponent("store/tiles/dataset"), store: synthetic.store, bundle: bundle)
        let report = try PruningStudy.run(inputs, settings: s, parts: Set(PruningPart.allCases))
        let warp = try #require(report.warp)
        #expect(warp.trees.count == 2 && warp.depths.count == 1 && warp.permuted.count == 6 && warp.groupsDropped.count == 6 && warp.featuresDropped.count == 19)
        let fr = try #require(warp.featuresDropped.first { $0.name == "without FR" })
        #expect(fr.verdict == "costs AUC" && fr.primary.delta < -0.1, "FR carries the label")
        #expect(warp.groupsDropped.first { $0.name == "without residual" }?.verdict == "costs AUC")
        #expect(warp.permuted.first { $0.name == "residual" }?.verdict == "costs AUC")
        let others = warp.featuresDropped.filter { $0.name != "without FR" }
        // 58 test images: a refit's own noise is about ±0.01 AUC, so the others are held to a tenth of FR's cost.
        #expect(others.allSatisfy { $0.primary.delta > fr.primary.delta / 10 }, "no other feature carries anything")
        #expect(warp.droppedTogether.map { $0.primary.delta > fr.primary.delta / 10 } ?? true)
        #expect(warp.scores.map(\.name) == ["plain mean", "median", "tile vote"])
        #expect(warp.seeds.count == 1 && warp.groupsTogether.map(\.name) == ["without mirror, seam, cfa"])
        #expect(warp.groupsTogether[0].primary.delta > fr.primary.delta / 10, "the three groups carry nothing here")
        #expect(warp.calibration.agreeing == warp.calibration.images && warp.calibration.images == warp.testImages)
        #expect(abs(warp.shippedGain.values.reduce(0, +) - 1) < 1e-9 && warp.shippedGain.count == 19)
        let fusion = try #require(report.fusion)
        #expect(fusion.trees.count == 1 && fusion.depths.count == 1 && fusion.inputs.map(\.name)
                == ["without warp", "without capture", "without sharpness", "DINOv2 alone", "without DINOv2"])
        #expect(fusion.trainRows + fusion.testRows == fusion.rows && fusion.testRows > 0 && fusion.shippedPermuted.count == 4)
        #expect(fusion.seeds.count == 1 && fusion.inputsTogether.map(\.name) == ["without sharp and warp"])
        let stack = try #require(report.stack)
        #expect(stack.variants.count == 9 && stack.realRows + stack.generatedRows == stack.rows)
        for v in stack.variants {
            #expect((stack.movedToGenerated[v.name] ?? -1) + (stack.movedToReal[v.name] ?? -1) == v.primary.changedCalls, "\(v.name)")
            #expect((stack.shippedRight[v.name] ?? -1) >= 0 && (stack.shippedRight[v.name] ?? 0) <= v.primary.changedCalls, "\(v.name)")
        }
        #expect(report.rules.count == 5 && Set(report.seconds.keys) == ["warp", "fusion", "stack"])
        _ = try JSONCoding.prettyEncoder().encode(report)
    }
}
