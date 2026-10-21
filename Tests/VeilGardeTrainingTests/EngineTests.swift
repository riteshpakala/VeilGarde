//
//  EngineTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A whole recipe through the engine on a synthetic work area: the plan reads without
//        training, a refusal stops the run before a candidate exists, and the run writes a
//        candidate bundle that verifies, whose fusion head is a from-scratch fit over the 393
//        fusion columns with its evaluation twin reported, and whose heads and combiner load as
//        the detector loads them. A warm start keeps the parent's trees byte for byte; a parent of
//        another width cannot be warm-started.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeTraining

@Suite("Training engine", .serialized)
struct EngineTests {
    func recipe(id: String = "toy") -> TrainingRecipe {
        TrainingRecipe(id: id) {
            Combiner()
            FusionHead().scratch(trees: 12, eta: 0.1)
            for kind in [HeadKind.art, .blur, .human, .cgi, .artPair, .preview] { DinoHead(kind) }
        }
    }

    @Test("the plan names every stage and touches nothing")
    func plan() throws {
        let s = try SyntheticArea.make()
        defer { s.remove() }
        let engine = TrainingEngine(area: s.area, parent: s.parent, store: s.store)
        let plan = try engine.plan(recipe())
        #expect(plan.refusals.isEmpty, "\(plan.refusals)")
        #expect(plan.models.map(\.model) == ["fusion-head", "head:art", "head:blur", "head:human", "head:cgi", "head:art-pair", "head:preview", "combiner"])
        #expect(plan.summary.contains("from scratch: 12 trees"))
        #expect(plan.summary.contains("393 columns"))
        #expect(!FileManager.default.fileExists(atPath: plan.candidate.path))
    }

    @Test("a refusal stops the run before a candidate exists")
    func refusals() throws {
        let s = try SyntheticArea.make()
        defer { s.remove() }
        let engine = TrainingEngine(area: s.area, parent: s.parent, store: s.store)
        let bad = TrainingRecipe(id: "bad") { DinoHead(.semtile) }
        let plan = try engine.plan(bad)
        #expect(plan.refusals.count == 1, "semtile has no tokens in the store")
        #expect(throws: VeilGardeFailure.self) { try engine.train(bad) }
        #expect(!FileManager.default.fileExists(atPath: plan.candidate.path))
        #expect(throws: VeilGardeFailure.self) { try engine.plan(TrainingRecipe(id: "a/b") { Combiner() }) }
    }

    @Test("a full recipe writes a candidate bundle the detector can load")
    func train() throws {
        let s = try SyntheticArea.make()
        defer { s.remove() }
        var lines: [String] = []
        let engine = TrainingEngine(area: s.area, parent: s.parent, store: s.store) { if let l = $0.line { lines.append(l) } }
        let outcome = try engine.train(recipe())
        let c = outcome.candidate
        try c.verify()
        let parent = try ModelBundle.load(s.parent)

        // The fusion head: a scratch fit over the 393 columns, no parent, the evaluation twin reported.
        let fusion = try #require(c.manifest.artifact(.fusionHead))
        #expect(fusion.parent == nil && fusion.file == "fusion/fusion_head.xgb.json")
        let head = try GBDTModel.load(c.url(.fusionHead)!)
        #expect(head.trees.count == 12 && head.featureCount == FusionVector.count)
        let metrics = try JSONSerialization.jsonObject(with: Data(contentsOf: c.root.appendingPathComponent("fusion/metrics.json"))) as! [String: Any]
        let report = try #require(metrics["report"] as? [String: Any])
        #expect((report["evaluationRows"] as? Int ?? 0) > 0 && report["evaluationAUC"] is Double)
        #expect(report["parentComparable"] as? Bool == true, "the shipped head reads the same 393 columns")

        // Heads and the combiner load as the detector loads them.
        for kind in [HeadKind.art, .blur, .human, .cgi, .artPair, .preview] {
            let url = try #require(c.url(.head, head: kind))
            #expect(url.path.hasSuffix("heads/\(kind.rawValue)/head.json"))
            #expect(try LinearHead.load(url).coef.count == 384)
        }
        let combiner = try StackCombiner.load(c.url(.combiner)!)
        #expect(combiner.wBase >= 0 && combiner.wGen.count == 3)
        #expect(combiner.pairAdjudicates == true, "this recipe trained an art-pair head, so its combiner adjudicates; the shipped recipe trains none")
        #expect(c.manifest.artifact(.combiner)?.file == "combiner/stack_combiner.json")
        // What the recipe did not name is the parent's, byte for byte.
        #expect(c.manifest.artifact(.head, head: .screenshot)?.sha256 == parent.sha256(.head, head: .screenshot))
        #expect(c.manifest.weights == parent.manifest.weights)
        // The record of the run.
        let runs = try String(contentsOf: c.root.appendingPathComponent("runs.jsonl"), encoding: .utf8).split(separator: "\n")
        #expect(runs.count > 10)
        #expect(lines.contains { $0.hasPrefix("candidate toy verified") })
        #expect(outcome.metrics.keys.sorted() == ["combiner", "fusion-head", "head:art", "head:art-pair", "head:blur", "head:cgi", "head:human", "head:preview"])
        #expect(try JSONDecoder().decode(TrainingRecipe.self, from: Data(contentsOf: c.root.appendingPathComponent("recipe.json"))) == recipe())
        // A second run under the same id is refused.
        #expect(throws: VeilGardeFailure.self) { try engine.train(recipe()) }
    }

    @Test("a both-readings recipe trains a 777-column head at its depth, its combiner reads that row, and a warm start onto the 393-column parent is refused")
    func bothReadings() throws {
        let s = try SyntheticArea.make()
        defer { s.remove() }
        let engine = TrainingEngine(area: s.area, parent: s.parent, store: s.store)
        let wide = TrainingRecipe(id: "wide") {
            FusionHead().scratch(trees: 6, eta: 0.3).columns(.bothReadings).depth(3)
            Combiner()
        }
        let c = try engine.train(wide).candidate
        try c.verify()
        let head = try GBDTModel.load(c.url(.fusionHead)!)
        #expect(head.featureCount == 777 && head.trees.count == 6 && head.trees.allSatisfy { $0.depth <= 3 })
        #expect(try StackCombiner.load(c.url(.combiner)!).wGen.count == 3)
        let warm = TrainingRecipe(id: "wide-warm") { FusionHead().warmStart(add: 2).columns(.bothReadings) }
        #expect(try engine.plan(warm).refusals.count == 1, "the parent's head reads 393 columns")
    }

    @Test("a warm start keeps the parent's trees byte for byte and records the parent")
    func warmStart() throws {
        let s = try SyntheticArea.make()
        defer { s.remove() }
        let engine = TrainingEngine(area: s.area, parent: s.parent, store: s.store)
        let c = try engine.train(TrainingRecipe(id: "warm") { FusionHead().warmStart(add: 3, eta: 0.03) }).candidate
        let parent = try ModelBundle.load(s.parent)
        #expect(c.manifest.artifact(.fusionHead)?.parent == parent.sha256(.fusionHead))
        let head = try GBDTModel.load(c.url(.fusionHead)!), before = try GBDTModel.load(parent.url(.fusionHead)!)
        #expect(head.trees.count == before.trees.count + 3)
        for i in 0..<before.trees.count { #expect(head.trees[i].raw == before.trees[i].raw) }
    }

    @Test("a parent of another width cannot be warm-started")
    func widthRefused() throws {
        let s = try SyntheticArea.make()
        defer { s.remove() }
        let dataset = try FusionDataset.assemble(FeatureStore(directory: s.store), settings: FusionSettings())
        var settings = FusionSettings()
        settings.mode = .warmStart(add: 2, eta: 0.03)
        let narrow = GBDTModel(trees: [], baseScoreProbability: 0.5, featureCount: 5)
        #expect(throws: VeilGardeFailure.self) { try FusionTrainer.train(dataset, settings: settings, parent: narrow) }
    }
}
