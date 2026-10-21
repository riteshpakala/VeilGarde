//
//  RedundancyTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The redundancy check on a synthetic area whose warp label signal is FR alone: the join
//        finds every image, each arm reports both reconstructions and the six gains under RR1's
//        verdicts, the residual view with FR beats the one without, a golden set equal to the trio
//        is the trio, and the verdict rule and the rank correlation hold on hand-made numbers.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeTraining

@Suite("Research: the redundancy check", .serialized)
struct RedundancyTests {
    @Test("on a synthetic area every arm reports its reconstructions, gains and coverage")
    func study() throws {
        let synthetic = try SyntheticArea.make(images: 800)
        defer { synthetic.remove() }
        let join = try SyntheticJoin.make(synthetic)
        var s = RedundancySettings()
        s.resamples = 40
        s.golden = [0, 1, 2, 16]
        s.warpParams = BoostParams(trees: 20, maxDepth: 3, eta: 0.3, subsample: 0.8, colsampleByTree: 0.8, seed: 0)
        s.stageParams = BoostParams(trees: 20, maxDepth: 3, eta: 0.3, subsample: 0.8, colsampleByTree: 0.8, seed: 0)
        let tiles = synthetic.area.root.appendingPathComponent("store/tiles/dataset")
        let report = try RedundancyStudy.run(RedundancyStudy.Inputs(tiles: tiles, store: join.store, aux: join.aux, bundle: try ModelBundle.load(synthetic.parent)), settings: s)
        #expect(report.arms.map(\.name) == ["trio", "golden", "residual10", "all19", "raw9"])
        #expect(report.counts["joined"] == 800 && (report.counts["held-out joined"] ?? 0) > 100)
        let verdicts: Set<String> = ["redundant", "complementary", "undetermined"]
        for arm in report.arms {
            #expect(arm.reconstruction.map(\.target) == ["noiseprint", "fusion"])
            #expect(arm.gains.count == 6 && arm.gains.allSatisfy { verdicts.contains($0.verdict) })
            #expect(arm.aucs.count == 7 && arm.coverage.captureAbsent > 0)
            #expect(arm.noiseprintVerdict == arm.gains[0].verdict && arm.dinoCaptureVerdict == arm.gains[1].verdict)
        }
        let trio = try #require(report.arms.first { $0.name == "trio" }), raw9 = try #require(report.arms.first { $0.name == "raw9" })
        #expect(trio.aucs["residual"]! > raw9.aucs["residual"]! + 0.15, "FR carries the label: \(trio.aucs["residual"]!) against \(raw9.aucs["residual"]!)")
        #expect(report.rules.count == 6 && report.rules.contains { $0.hasPrefix("RR1.") } && report.rules.contains { $0.hasPrefix("RR2.") })
        _ = try JSONCoding.prettyEncoder().encode(report)
    }

    @Test("the arms deduplicate, RR1 reads a gain, and the rank correlation is Spearman's")
    func rules() {
        var s = RedundancySettings()
        s.golden = [2, 1, 0]
        #expect(RedundancyStudy.arms(s).map(\.name) == ["trio", "residual10", "all19", "raw9"])
        func c(_ delta: Double, _ low: Double, _ high: Double) -> PairedComparison {
            PairedComparison(reference: 0.8, variant: 0.8 + delta, delta: delta, low: low, high: high, items: 100, changedCalls: 0, changedShare: 0)
        }
        #expect(RedundancyStudy.verdict(c(0.004, -0.01, 0.02), s) == "redundant")
        #expect(RedundancyStudy.verdict(c(-0.02, -0.04, 0.0), s) == "redundant")
        #expect(RedundancyStudy.verdict(c(0.02, 0.01, 0.03), s) == "complementary")
        #expect(RedundancyStudy.verdict(c(0.02, -0.001, 0.04), s) == "undetermined")
        #expect(RedundancyStudy.spearman([1, 2, 3, 4], [10, 20, 30, 45]) == 1)
        #expect(RedundancyStudy.spearman([1, 2, 3, 4], [4, 3, 2, 1]) == -1)
        #expect(abs(RedundancyStudy.spearman([1, 1, 2, 3], [5, 6, 7, 8]) - 0.9486832980505138) < 1e-12, "ties take their average rank")
    }
}
