//
//  RecipeTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The recipe DSL: the builder takes `if` and `for`, modifiers return changed copies, the
//        engine's order is the dependency order (the camera head, the heads, the combiner), recipes
//        round-trip as JSON through their members' kinds, and recipe.toml reads into the same
//        values, refusing what it does not know (the fusion table and its columns among it).
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeTraining

@Suite("Training recipes")
struct RecipeTests {
    @Test("the builder, the modifiers and the dependency order")
    func builder() throws {
        let withPreview = true
        let recipe = TrainingRecipe(id: "r") {
            Combiner().realsWeight(2)
            for kind in [HeadKind.art, .blur] { SpecialistHead(kind).regularization(C: 0.25) }
            if withPreview { SpecialistHead(.preview) }
            CameraHead().warmStart(add: 10)
        }
        #expect(recipe.ordered.map(\.name) == ["camera", "head:art", "head:blur", "head:preview", "combiner"])
        let camera = try #require(recipe.ordered[0] as? CameraHead)
        #expect(camera.settings.mode == .warmStart(add: 10, eta: 0.03))
        let preview = try #require(recipe.ordered[3] as? SpecialistHead)
        #expect(!preview.settings.admission && preview.negatives == .real("preview"))
        let human = SpecialistHead(.human)
        #expect(human.regularization(C: 2).settings.C == 2 && human.settings.C == 0.5)
        let data = try JSONEncoder().encode(recipe)
        #expect(try JSONDecoder().decode(TrainingRecipe.self, from: data) == recipe)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"kind\":\"camera\"") && text.contains("\"kind\":\"specialist\"") && text.contains("\"kind\":\"combiner\""))
        #expect(throws: (any Error).self, "a recipe.json naming a kind this build does not train") {
            try JSONDecoder().decode(TrainingRecipe.self, from: Data(#"{"id":"x","members":[{"kind":"fusion","member":{}}]}"#.utf8))
        }
    }

    @Test("the shipped preset trains every member the store reproduces: the camera head from scratch, three heads, the preview head, the combiner")
    func shipped() throws {
        let recipe = TrainingRecipe.shipped(id: "s")
        #expect(recipe.ordered.map(\.name) == ["camera", "head:art", "head:blur", "head:human", "head:preview", "combiner"])
        let camera = try #require(recipe.ordered[0] as? CameraHead)
        #expect(camera.settings.mode == .scratch(trees: 500, eta: 0.04))
        #expect(HeadKind.flywheelCategories == [.art, .blur, .human])
        #expect(TrainingRecipe.kindNames == ["camera", "specialist", "combiner"])
    }

    @Test("recipe.toml reads into the same recipe")
    func toml() throws {
        let text = """
        id = "weekly"   # a comment
        [camera]
        mode = "warm"
        add = 20
        [heads]
        kinds = ["art", "preview"]
        [combiner]
        reals_weight = 2.0
        """
        let recipe = try RecipeFile.parse(text)
        let expected = TrainingRecipe(id: "weekly") {
            CameraHead().warmStart(add: 20, eta: 0.03)
            SpecialistHead(.art)
            SpecialistHead(.preview)
            Combiner().realsWeight(2)
        }
        #expect(recipe == expected)
        let scratch = try RecipeFile.parse("id = \"s\"\n[camera]\nmode = \"scratch\"\ntrees = 50\ndepth = 7")
        #expect(scratch == TrainingRecipe(id: "s") { CameraHead().scratch(trees: 50, eta: 0.04).depth(7) })
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"x\"\n[camera]\ncolour = 1") }
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"x\"\n[optimizer]\nlr = 1") }
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("[heads]\nkinds = [\"art\"]") }
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"x\"\n[heads]\nkinds = [\"faces\"]") }
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"x\"\n[camera]\ndepth = 40") }
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"x\"\n[fusion]\nmode = \"warm\"") }
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"x\"\n[camera]\ncolumns = \"dino_fusion,cap\"") }
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"x\"\n[combiner]\nout_of_fold = 5") }
    }
}
