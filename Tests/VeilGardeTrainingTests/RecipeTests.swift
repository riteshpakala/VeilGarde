//
//  RecipeTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The recipe DSL: the builder takes `if` and `for`, modifiers return changed copies, the
//        engine's order is the dependency order, recipes round-trip as JSON, and recipe.toml
//        reads into the same values (refusing what it does not know).
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeTraining

@Suite("Training recipes")
struct RecipeTests {
    let dataset = URL(fileURLWithPath: "/data/final_mixed")

    @Test("the builder, the modifiers and the dependency order")
    func builder() throws {
        let withPair = true
        let recipe = TrainingRecipe(id: "r") {
            Combiner().realsWeight(2)
            for kind in [HeadKind.art, .blur] { DinoHead(kind).regularization(C: 0.25) }
            if withPair { DinoHead(.artPair) }
            FusionHead().warmStart(add: 10)
            SensorCalibration().band(0.05)
            WarpTileModel(dataset: dataset).shape(.v18).trees(50)
        }
        #expect(recipe.ordered.map(\.name) == ["warp-tile", "sensor-calibration", "fusion-head", "head:art", "head:blur", "head:art-pair", "combiner"])
        guard case .warpTile(let w) = recipe.ordered[0] else { Issue.record("no warp"); return }
        #expect(w.params.trees == 50 && w.params.maxDepth == 4 && w.params.earlyStoppingRounds == 30)
        guard case .head(let pair) = recipe.ordered[5] else { Issue.record("no pair"); return }
        #expect(pair.settings.classWeight == .none && pair.settings.fireThreshold == nil && !pair.settings.admission)
        let base = DinoHead(.human)
        #expect(base.regularization(C: 2).settings.C == 2 && base.settings.C == 0.5)
        let data = try JSONEncoder().encode(recipe)
        #expect(try JSONDecoder().decode(TrainingRecipe.self, from: data) == recipe)
    }

    @Test("the shipped preset trains every model the store can reproduce")
    func shipped() {
        let names = TrainingRecipe.shipped(id: "s", dataset: dataset).ordered.map(\.name)
        #expect(names == ["warp-tile", "sensor-calibration", "fusion-head", "head:art", "head:blur", "head:human", "head:cgi", "head:preview", "combiner"])
        #expect(WarpShape.deployed.params == BoostParams(trees: 200, maxDepth: 8, eta: 0.1, subsample: 0.8, colsampleByTree: 0.8, seed: 0))
    }

    @Test("recipe.toml reads into the same recipe")
    func toml() throws {
        let text = """
        id = "weekly"   # a comment
        [warp]
        dataset = "/data/final_mixed"
        shape = "v18"
        sample_per_label = 40
        [calibration]
        band = 0.05
        [fusion]
        mode = "warm"
        add = 20
        [heads]
        kinds = ["art", "art-pair"]
        [combiner]
        reals_weight = 2.0
        """
        let recipe = try RecipeFile.parse(text)
        let expected = TrainingRecipe(id: "weekly") {
            WarpTileModel(dataset: dataset).shape(.v18).sample(perLabel: 40)
            SensorCalibration().band(0.05)
            FusionHead().warmStart(add: 20, eta: 0.03)
            DinoHead(.art)
            DinoHead(.artPair)
            Combiner().realsWeight(2)
        }
        #expect(recipe == expected)
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"x\"\n[warp]\ndataset = \"/d\"\ncolour = 1") }
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"x\"\n[optimizer]\nlr = 1") }
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("[heads]\nkinds = [\"art\"]") }
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"x\"\n[heads]\nkinds = [\"faces\"]") }
    }
}
