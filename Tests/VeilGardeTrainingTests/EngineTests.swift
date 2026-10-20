//
//  EngineTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A whole recipe through the engine on a synthetic work area: the plan reads without
//        training, a refusal stops the run before a candidate exists, and the run writes a
//        candidate bundle that verifies, whose warp model is its own sensor model with a
//        calibration bound to it, whose fusion head keeps the parent's 940 trees byte for byte,
//        and whose heads and combiner load as the detector loads them.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeTraining

@Suite("Training engine", .serialized)
struct EngineTests {
    func recipe(_ s: SyntheticArea, id: String = "toy") -> TrainingRecipe {
        TrainingRecipe(id: id) {
            Combiner()
            WarpTileModel(dataset: s.dataset).trees(12).depth(3)
            SensorCalibration()
            FusionHead().warmStart(add: 3, eta: 0.03).allowMixedWarp(false)
            for kind in [HeadKind.art, .blur, .human, .cgi, .artPair, .preview] { DinoHead(kind) }
        }
    }

    @Test("the plan names every stage and touches nothing")
    func plan() throws {
        let s = try SyntheticArea.make()
        defer { s.remove() }
        let engine = TrainingEngine(area: s.area, parent: s.parent, store: s.store)
        let plan = try engine.plan(recipe(s))
        #expect(plan.refusals.isEmpty, "\(plan.refusals)")
        #expect(plan.models.map(\.model) == ["warp-tile", "sensor-calibration", "fusion-head", "head:art", "head:blur", "head:human", "head:cgi", "head:art-pair", "head:preview", "combiner"])
        let warp = plan.models[0]
        #expect(warp.stages.first?.stage == .tiles && warp.stages.first?.runs == false, "the tiles are cached")
        #expect(plan.summary.contains("deployed: 12 trees, depth 3"))
        #expect(!FileManager.default.fileExists(atPath: plan.candidate.path))
    }

    @Test("a refusal stops the run before a candidate exists")
    func refusals() throws {
        let s = try SyntheticArea.make(mixedWarp: true)
        defer { s.remove() }
        let engine = TrainingEngine(area: s.area, parent: s.parent, store: s.store)
        let bad = TrainingRecipe(id: "bad") { DinoHead(.semtile); FusionHead() }
        let plan = try engine.plan(bad)
        #expect(plan.refusals.count == 2, "semtile has no tokens; the store mixes warp models")
        #expect(throws: VeilGardeFailure.self) { try engine.train(bad) }
        #expect(!FileManager.default.fileExists(atPath: plan.candidate.path))
        #expect(try engine.plan(TrainingRecipe(id: "ok") { FusionHead().allowMixedWarp() }).refusals.isEmpty)
        #expect(throws: VeilGardeFailure.self) { try engine.plan(TrainingRecipe(id: "a/b") { Combiner() }) }
    }

    @Test("a full recipe writes a candidate bundle the detector can load")
    func train() throws {
        let s = try SyntheticArea.make()
        defer { s.remove() }
        var lines: [String] = []
        let engine = TrainingEngine(area: s.area, parent: s.parent, store: s.store) { if let l = $0.line { lines.append(l) } }
        let outcome = try engine.train(recipe(s))
        let c = outcome.candidate
        try c.verify()
        let parent = try ModelBundle.load(s.parent)

        // The warp model is its own sensor model, and the calibration is bound to it.
        let warp = try #require(c.manifest.artifact(.warpTile)), sensor = try #require(c.manifest.artifact(.warpMajoritySensor))
        #expect(warp.sha256 == sensor.sha256 && warp.file == "warp/warp_tile32.xgb.json")
        #expect(warp.sha256 != parent.sha256(.warpTile))
        let model = try GBDTModel.load(c.url(.warpTile)!)
        #expect(model.trees.count == 12 && model.featureNames == WarpFeatures.names)
        let calibration = try Data(contentsOf: c.url(.sensorCalibration)!)
        let contract = try SensorCalibrationContract.decode(calibration, expectedModelSHA256: warp.sha256, expectedSensorVariant: "warp19")
        #expect(contract.transform == .cuts, "the engine writes the fitted contract as two cuts on the vote")

        // The fusion head continues the parent's: 940 trees untouched, 3 appended, the parent recorded.
        let fusion = try #require(c.manifest.artifact(.fusionHead))
        #expect(fusion.parent == parent.sha256(.fusionHead))
        let head = try GBDTModel.load(c.url(.fusionHead)!), before = try GBDTModel.load(parent.url(.fusionHead)!)
        #expect(head.trees.count == before.trees.count + 3)
        for i in 0..<before.trees.count { #expect(head.trees[i].raw == before.trees[i].raw) }

        // Heads and the combiner load as the detector loads them.
        for kind in [HeadKind.art, .blur, .human, .cgi, .artPair, .preview] {
            let url = try #require(c.url(.head, head: kind))
            #expect(url.path.hasSuffix("heads/\(kind.rawValue)/head.json"))
            #expect(try LinearHead.load(url).coef.count == 384)
            #expect(FileManager.default.fileExists(atPath: c.root.appendingPathComponent("heads/\(kind.rawValue)/metrics.json").path))
        }
        let combiner = try JSONDecoder().decode(StackCombiner.self, from: Data(contentsOf: c.url(.combiner)!))
        #expect(combiner.wBase >= 0)
        #expect(combiner.pairAdjudicates == true, "this recipe trained an art-pair head, so its combiner adjudicates; the shipped recipe trains none")
        // What the recipe did not name is the parent's, byte for byte.
        #expect(c.manifest.artifact(.head, head: .screenshot)?.sha256 == parent.sha256(.head, head: .screenshot))
        #expect(c.manifest.artifact(.fusionReference)?.sha256 == parent.sha256(.fusionReference))
        #expect(c.manifest.weights == parent.manifest.weights)
        // The record of the run.
        let runs = try String(contentsOf: c.root.appendingPathComponent("runs.jsonl"), encoding: .utf8).split(separator: "\n")
        #expect(runs.count > 20)
        #expect(lines.contains { $0.hasPrefix("candidate toy verified") })
        #expect(outcome.metrics.keys.sorted() == ["combiner", "fusion-head", "head:art", "head:art-pair", "head:blur", "head:cgi", "head:human", "head:preview", "sensor-calibration", "warp-tile"])
        #expect(try JSONDecoder().decode(TrainingRecipe.self, from: Data(contentsOf: c.root.appendingPathComponent("recipe.json"))) == recipe(s))
        // A second run under the same id is refused.
        #expect(throws: VeilGardeFailure.self) { try engine.train(recipe(s)) }
    }

    @Test("a warp model retrained without its calibration drops the parent's contract")
    func warpAlone() throws {
        let s = try SyntheticArea.make()
        defer { s.remove() }
        let engine = TrainingEngine(area: s.area, parent: s.parent, store: s.store)
        let r = TrainingRecipe(id: "warp-only") { WarpTileModel(dataset: s.dataset).trees(4).depth(2) }
        #expect(try engine.plan(r).models[0].notes.contains { $0.contains("falls back to identity") })
        let c = try engine.train(r).candidate
        #expect(c.manifest.artifact(.sensorCalibration) == nil)
        try c.verify()
    }
}
