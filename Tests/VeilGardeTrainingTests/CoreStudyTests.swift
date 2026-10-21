//
//  CoreStudyTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The core study on a synthetic work area whose only label signal is FR: every arm's model
//        stays 19 wide and splits only inside its mask, the trio keeps the full model's vote while
//        the raw nine lose it, forward selection finds nothing to add, every arm gets cuts of its
//        own, the rules ride in the report, and a left-out pool leaves training and is scored
//        whole. The synthetic test partition is about 180 images of four tiles, so the test widens
//        R2's tolerances to make the trio's win deterministic. The golden rule, alone: the
//        smallest qualifying arm wins, ties go to the forward path, and the full model is named
//        when nothing qualifies.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeTraining

@Suite("Research: the core study", .serialized)
struct CoreStudyTests {
    static func settings() -> CoreSettings {
        var s = CoreSettings()
        s.resamples = 60
        s.seedControls = [1]
        s.warpParams = BoostParams(trees: 30, maxDepth: 3, eta: 0.3, subsample: 0.8, colsampleByTree: 0.8, seed: 0)
        s.aucTolerance = 0.05
        s.poolTolerance = 0.2
        return s
    }

    @Test("on a synthetic area the trio is the core, every arm stays 19 wide, and the report carries its rules")
    func study() throws {
        let synthetic = try SyntheticArea.make(images: 1200)
        defer { synthetic.remove() }
        let tiles = synthetic.area.root.appendingPathComponent("store/tiles/dataset")
        let report = try CoreStudy.run(CoreStudy.Inputs(tiles: tiles, bundle: try ModelBundle.load(synthetic.parent)), settings: Self.settings())
        let registered = CoreStudy.registeredArms(Self.settings()).map(\.name)
        #expect(registered.count == 27, "all19, one seed control, the trio, 16 singles, 6 groups, 2 controls")
        #expect(Array(report.rows.map(\.arm.name).prefix(registered.count)) == registered)
        #expect(report.rows.allSatisfy { $0.width == WarpFeatures.count }, "every model stays 19 wide")
        #expect(report.rows.allSatisfy { Set($0.splitColumns).isSubset(of: Set($0.arm.allowed)) }, "every model splits inside its mask")
        let row: (String) throws -> CoreArmRow = { name in try #require(report.rows.first { $0.arm.name == name }) }
        let all19 = try row("all19"), trio = try row("trio"), raw9 = try row("raw9")
        #expect(all19.againstAll19.vote.delta == 0 && trio.againstTrio.vote.delta == 0)
        #expect(trio.distance == "within tolerance" || trio.distance == "better", "FR carries the label, so the trio keeps the vote")
        #expect(raw9.distance == "costs AUC" && raw9.metrics.imageMajorityAUC < 0.6, "without FR nothing is left")
        #expect(try row("residual10").metrics.imageMajorityAUC > raw9.metrics.imageMajorityAUC + 0.1)
        #expect(raw9.needle == "costs vote AUC" && all19.needle != "moves the needle")
        #expect(report.rows.allSatisfy { $0.calibration.validationImages == report.partitions.validationImages && $0.calibration.realAtOrBelow < $0.calibration.generatedAtOrAbove })
        #expect(all19.cameraRealShare != nil && all19.pools.contains { $0.pool == "iphone" && $0.label == 0 })
        #expect(report.forward.first?.candidates.count == 16, "step 1 weighs every non-trio feature")
        #expect(report.forward.last?.stopped != nil, "noise adds nothing, so the selection stops")
        #expect(trio.forwardStep == 0)
        #expect(report.rules.count == 8 && report.rules.contains { $0.hasPrefix("R2.") } && report.rules.contains { $0.contains("19 columns wide") })
        #expect(report.golden.name == "trio" && report.golden.qualifies, "the smallest arm holding FR: \(report.golden.name)")
        #expect(trio.qualifies && !raw9.qualifies && report.golden.qualifying.first == "trio")
        #expect(report.shipped?.metrics.images == report.partitions.scoredImages)
        _ = try JSONCoding.prettyEncoder().encode(report)

        // A left-out pool leaves train and validation and is scored whole.
        var s = Self.settings()
        s.leavePoolOut = "iphone"
        s.forwardSelection = false
        s.arms = ["raw9"]
        let out = try CoreStudy.run(CoreStudy.Inputs(tiles: tiles), settings: s)
        let shards = try TileCache(directory: tiles).load()
        let images = shards.flatMap(\.images)
        let iphone = images.filter { $0.pool == "iphone" }
        #expect(out.partitions.leftOutImages == iphone.count && iphone.count > 0)
        #expect(out.partitions.trainImages == images.filter { $0.split == .train && $0.pool != "iphone" }.count)
        #expect(out.partitions.validationImages == images.filter { $0.split == .val && $0.pool != "iphone" }.count)
        #expect(out.partitions.scoredImages == images.filter { $0.split == .test || $0.pool == "iphone" }.count)
        #expect(out.rows.map(\.arm.name) == ["all19", "seed 1", "trio", "raw9"] && out.forward.isEmpty)
        #expect(out.rows[0].pools.first { $0.pool == "iphone" }?.images == iphone.count)
        #expect(throws: VeilGardeFailure.self) { var bad = Self.settings(); bad.arms = ["trio+colour"]; _ = try CoreStudy.chosenArms(bad) }
        let across = CoreStudy.golden(across: [report, out])
        #expect(across.name == "trio" && across.qualifies, "the trio qualifies in both runs: \(across.reason)")
    }

    @Test("the golden rule: the smallest qualifying arm, ties to the forward path, else the full model")
    func goldenRule() {
        let s = CoreSettings()
        let reference = CoreStudy.GoldenInput(name: "all19", columns: Array(0..<19), voteAUC: 0.80, cameraRealShare: 0.90, generatedCalledReal: 0.10,
                                              forwardStep: Int.max, order: 0)
        func arm(_ name: String, _ columns: [Int], vote: Double, camera: Double? = 0.90, generatedReal: Double = 0.10, step: Int = Int.max, order: Int) -> CoreStudy.GoldenInput {
            CoreStudy.GoldenInput(name: name, columns: columns, voteAUC: vote, cameraRealShare: camera, generatedCalledReal: generatedReal, forwardStep: step, order: order)
        }
        let trio = arm("trio", [0, 1, 2], vote: 0.70, step: 0, order: 1)
        let a = arm("trio+cfa_G", [0, 1, 2, 11], vote: 0.797, order: 2)
        let b = arm("trio+nyq_R", [0, 1, 2, 18], vote: 0.799, step: 1, order: 3)
        let c = arm("trio+raw9", Array(0..<3) + Array(10..<19), vote: 0.81, order: 4)
        let g = CoreStudy.golden([trio, a, b, c], reference: reference, s)
        #expect(g.name == "trio+nyq_R" && g.qualifies, "both four-column arms qualify; the one on the forward path wins")
        #expect(g.qualifying == ["trio+nyq_R", "trio+cfa_G", "trio+raw9"])
        #expect(!CoreStudy.qualifies(arm("x", [0, 1, 2, 5], vote: 0.794, order: 5), reference: reference, s), "0.006 under the full model")
        #expect(!CoreStudy.qualifies(arm("x", [0, 1, 2, 5], vote: 0.80, camera: 0.87, order: 5), reference: reference, s), "the camera share fell 3 points")
        #expect(!CoreStudy.qualifies(arm("x", [0, 1, 2, 5], vote: 0.80, generatedReal: 0.13, order: 5), reference: reference, s))
        #expect(CoreStudy.qualifies(arm("x", [0, 1, 2, 5], vote: 0.80, camera: 0.885, generatedReal: 0.115, order: 5), reference: reference, s))
        let none = CoreStudy.golden([trio], reference: reference, s)
        #expect(none.name == "all19" && !none.qualifies && none.columns.count == 19)
    }
}
