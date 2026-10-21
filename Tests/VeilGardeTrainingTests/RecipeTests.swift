//
//  RecipeTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The recipe DSL: the builder takes `if` and `for`, modifiers return changed copies, the
//        engine's order is the dependency order (fusion, heads, combiner), recipes round-trip as
//        JSON, and recipe.toml reads into the same values, the fusion head's columns and depth
//        among them, refusing what it does not know (the retired warp, calibration and noiseprint
//        tables among it).
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeTraining

@Suite("Training recipes")
struct RecipeTests {
    @Test("the builder, the modifiers and the dependency order")
    func builder() throws {
        let withPair = true
        let recipe = TrainingRecipe(id: "r") {
            Combiner().realsWeight(2)
            for kind in [HeadKind.art, .blur] { DinoHead(kind).regularization(C: 0.25) }
            if withPair { DinoHead(.artPair) }
            FusionHead().warmStart(add: 10)
        }
        #expect(recipe.ordered.map(\.name) == ["fusion-head", "head:art", "head:blur", "head:art-pair", "combiner"])
        guard case .fusion(let f) = recipe.ordered[0] else { Issue.record("no fusion"); return }
        #expect(f.settings.mode == .warmStart(add: 10, eta: 0.03))
        guard case .head(let pair) = recipe.ordered[3] else { Issue.record("no pair"); return }
        #expect(pair.settings.classWeight == .none && pair.settings.fireThreshold == nil && !pair.settings.admission)
        let base = DinoHead(.human)
        #expect(base.regularization(C: 2).settings.C == 2 && base.settings.C == 0.5)
        let data = try JSONEncoder().encode(recipe)
        #expect(try JSONDecoder().decode(TrainingRecipe.self, from: data) == recipe)
    }

    @Test("the shipped preset trains every model the store reproduces: the fusion head from scratch, three heads, the preview head, the combiner")
    func shipped() {
        let recipe = TrainingRecipe.shipped(id: "s")
        #expect(recipe.ordered.map(\.name) == ["fusion-head", "head:art", "head:blur", "head:human", "head:preview", "combiner"])
        guard case .fusion(let f) = recipe.ordered[0] else { Issue.record("no fusion"); return }
        #expect(f.settings.mode == .scratch(trees: 500, eta: 0.04))
        #expect(HeadKind.flywheelCategories == [.art, .blur, .human])
    }

    @Test("recipe.toml reads into the same recipe")
    func toml() throws {
        let text = """
        id = "weekly"   # a comment
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
            FusionHead().warmStart(add: 20, eta: 0.03)
            DinoHead(.art)
            DinoHead(.artPair)
            Combiner().realsWeight(2)
        }
        #expect(recipe == expected)
        let scratch = try RecipeFile.parse("id = \"s\"\n[fusion]\nmode = \"scratch\"\ntrees = 50")
        #expect(scratch == TrainingRecipe(id: "s") { FusionHead().scratch(trees: 50, eta: 0.04) })
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"x\"\n[fusion]\ncolour = 1") }
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"x\"\n[optimizer]\nlr = 1") }
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("[heads]\nkinds = [\"art\"]") }
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"x\"\n[heads]\nkinds = [\"faces\"]") }
        let wide = try RecipeFile.parse("id = \"w\"\n[fusion]\nmode = \"scratch\"\ntrees = 1000\ndepth = 7\ncolumns = \"dino_fusion,dino_norm,cap\"")
        #expect(wide == TrainingRecipe(id: "w") { FusionHead().scratch(trees: 1000, eta: 0.04).depth(7).columns(.bothReadings) })
        guard case .fusion(let f) = wide.ordered[0] else { Issue.record("no fusion"); return }
        #expect(f.settings.resolvedLayout.width == 777 && f.settings.maxDepth == 7)
        #expect(FusionHead().settings.resolvedLayout == .dinoCapture, "a recipe that names no columns means the 393-column row")
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"x\"\n[fusion]\ncolumns = \"dino_norm\"") }
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"x\"\n[fusion]\ndepth = 40") }
        for retired in ["warp", "calibration", "noiseprint"] {
            #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"x\"\n[\(retired)]\nseed = 1") }
        }
    }
}
