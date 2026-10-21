//
//  CondensedTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The condensed model. On the CPU: its inputs pad and mask every image's tiles to one grid
//        and standardize with the training images' statistics, and the threshold arithmetic its
//        rules read (the false-positive rate at a recall, the operating point) is right on
//        hand-made scores. On the GPU: every arm trains, writes weights that load back, is judged
//        by four rules, and the same seed gives the same model.
//

import Foundation
import MLX
import Testing
import VeilGardeCore
@testable import VeilGardeTraining

@Suite("Research: the condensed model's arithmetic")
struct CondensedArithmeticTests {
    @Test("the inputs pad, mask and standardize by the training images")
    func inputs() throws {
        let synthetic = try SyntheticArea.make(images: 200)
        defer { synthetic.remove() }
        let j = try SyntheticJoin.make(synthetic)
        let join = try ResearchJoin.finalMixed(tiles: synthetic.area.root.appendingPathComponent("store/tiles/dataset"), store: j.store, aux: j.aux)
        #expect(join.images.count == 200 && join.counts["joined"] == 200)
        let train = join.indices(in: [.train]), columns = [0, 1, 2]
        let z = CondensedSet.normalizer(join, train: train, columns: columns)
        let set = CondensedSet(join, rows: train, columns: columns, normalizer: z, maxTiles: 8)
        #expect(set.tileChannels == 6 && set.aggregateWidth == 12)
        #expect(set.tiles.count == train.count * 8 * 6 && set.mask.count == train.count * 8)
        #expect(set.mask.enumerated().allSatisfy { k, m in (k % 8 < 4) == (m == 1) }, "four tiles each, the rest padding")
        var fr = [Float]()
        for n in 0..<set.count { for k in 0..<4 { fr.append(set.tiles[(n * 8 + k) * 6]) } }
        let mean = fr.reduce(0, +) / Float(fr.count)
        #expect(abs(mean) < 1e-3, "FR standardized on the training tiles: mean \(mean)")
        #expect(set.provenance.count == set.count * CondensedSet.provenanceWidth && set.semantic.count == set.count * CondensedSet.semanticWidth)
        let battery = try ResearchJoin.battery(tiles: j.batteryTiles, aux: j.aux)
        #expect(battery.images.count == 24 && battery.images.allSatisfy { $0.tag != nil && $0.noiseprint.isFinite })
    }

    @Test("the false-positive rate at a recall and the operating point")
    func thresholds() throws {
        let p: [Float] = [0.9, 0.8, 0.7, 0.6, 0.65, 0.3, 0.2, 0.1], y: [Float] = [1, 1, 1, 1, 0, 0, 0, 0]
        #expect(CondensedTrainer.fpr(p, y, atRecall: 0.5) == 0, "two of four generated reached at 0.8; no real at or above")
        #expect(CondensedTrainer.fpr(p, y, atRecall: 1.0) == 0.25, "all four at 0.6; one real at 0.65")
        let op = try CondensedTrainer.operating(validation: p, validationLabels: y, test: p, testLabels: y, camera: [5, 6], maxRealFPR: 0.25)
        #expect(op.realFPR <= 0.25 && op.recall == 1 && op.cameraRealShare == 1 && op.auc == 0.9375)
    }
}

extension TrainingMLXSuites {
    @Suite("The condensed model on the GPU", .serialized)
    struct CondensedOnGPU {
        @Test("every arm trains, writes weights that load back, is judged by four rules, and a seed names one model")
        func arms() throws {
            let synthetic = try SyntheticArea.make(images: 800)
            defer { synthetic.remove() }
            let j = try SyntheticJoin.make(synthetic)
            var s = CondensedSettings()
            s.epochs = 3
            s.patience = 2
            s.seeds = [0]
            s.golden = [0, 1, 2, 16]
            s.arms = ["full@golden", "residual-only@golden", "semantic+provenance", "aggregates@golden"]
            s.warpParams = BoostParams(trees: 10, maxDepth: 3, eta: 0.3, subsample: 0.8, colsampleByTree: 0.8, seed: 0)
            s.stageParams = BoostParams(trees: 10, maxDepth: 3, eta: 0.3, subsample: 0.8, colsampleByTree: 0.8, seed: 0)
            let out = synthetic.root.appendingPathComponent("condensed", isDirectory: true)
            let inputs = CondensedTrainer.Inputs(tiles: synthetic.area.root.appendingPathComponent("store/tiles/dataset"), store: j.store, aux: j.aux,
                                                 batteryTiles: j.batteryTiles, bundle: try ModelBundle.load(synthetic.parent), output: out)
            let report = try CondensedTrainer.run(inputs, settings: s)
            #expect(report.arms.map(\.arm.name) == s.arms!)
            for a in report.arms {
                #expect(a.rules.count == 4 && a.admissible == a.rules.allSatisfy(\.passed))
                #expect(a.parameters > 0 && a.battery.hardImages == 12 && a.model.auc.isFinite)
                let weights = try loadArrays(url: URL(fileURLWithPath: try #require(a.weights)))
                #expect(!weights.isEmpty && weights.values.reduce(0) { $0 + $1.size } == a.parameters)
            }
            let full = report.arms[0], residual = report.arms[1]
            #expect(full.shape.semantic && full.shape.provenance && full.shape.tileChannels == 7 && !residual.shape.semantic)
            #expect(report.arms[3].shape.aggregateWidth == 16 && report.arms[3].shape.tileChannels == 0)
            #expect(report.rules.count == 7)
            s.arms = ["residual-only@golden"]
            let again = try CondensedTrainer.run(CondensedTrainer.Inputs(tiles: inputs.tiles, store: j.store, aux: j.aux, batteryTiles: j.batteryTiles,
                                                                         bundle: inputs.bundle, output: nil), settings: s)
            #expect(again.arms[0].model.auc == residual.model.auc, "the same seed trains the same model")
            _ = try JSONCoding.prettyEncoder().encode(report)
        }
    }
}
