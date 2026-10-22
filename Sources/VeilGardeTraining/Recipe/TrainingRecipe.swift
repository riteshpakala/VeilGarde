//
//  TrainingRecipe.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A training run as one declaration, written the way the detector's pipeline is: one
//        trainable member per line, `if` and `for` where the set depends on something. Each member
//        is a value with copy modifiers, so it reads top to bottom and builds nothing until the
//        engine runs it.
//
//            let recipe = TrainingRecipe(id: "weekly-2026-10") {
//                CameraHead().warmStart(add: 80, eta: 0.03)
//                for kind in HeadKind.flywheelCategories { SpecialistHead(kind) }
//                Combiner().realsWeight(3)
//            }
//            let engine = TrainingEngine(area: area, parent: shippedBundle, store: storeDirectory)
//            print(try engine.plan(recipe).summary)     // reads files, trains nothing
//            let outcome = try engine.train(recipe)     // writes candidates/<id>/
//
//  PIN:  The engine trains in dependency order (each member's rank: the camera head, the heads,
//        the combiner) whatever the declaration order, because the combiner reads the others.
//        Every member trains on the features-only store. `kinds` lists the member types a
//        recipe.json or recipe.toml may name; the Swift declaration needs no registration.
//

import Foundation
import VeilGardeCore

public struct TrainingRecipe: Sendable, Equatable, Codable {
    /// The trainable member types this build knows, for reading recipe files.
    public static let kinds: [any TrainableMember.Type] = [CameraHead.self, SpecialistHead.self, Combiner.self]

    /// The member type a recipe file names, or nil.
    public static func kind(named name: String) -> (any TrainableMember.Type)? {
        for type in kinds where type.recipeKind == name { return type }
        return nil
    }

    /// The names a recipe file may use.
    public static var kindNames: [String] {
        var names: [String] = []
        for type in kinds { names.append(type.recipeKind) }
        return names
    }

    public var id: String
    public var members: [AnyTrainable]

    public init(id: String, @TrainingBuilder _ content: () throws -> [AnyTrainable]) rethrows {
        self.id = id
        self.members = try content()
    }

    public init(id: String, members: [AnyTrainable]) {
        self.id = id
        self.members = members
    }

    /// The members in the order they train.
    public var ordered: [any TrainableMember] {
        members.enumerated().sorted { ($0.element.member.rank, $0.offset) < ($1.element.member.rank, $1.offset) }.map(\.element.member)
    }

    /// The shipped detector's trainable members, as the store reproduces them: the camera head from
    /// scratch, the three category heads, the preview head, and the combiner.
    public static func shipped(id: String) -> TrainingRecipe {
        TrainingRecipe(id: id) {
            CameraHead().scratch(trees: 500, eta: 0.04)
            for kind in HeadKind.flywheelCategories { SpecialistHead(kind) }
            SpecialistHead(.preview)
            Combiner()
        }
    }
}

@resultBuilder
public enum TrainingBuilder {
    public static func buildExpression(_ member: some TrainableMember) -> [AnyTrainable] { [AnyTrainable(member)] }
    public static func buildExpression(_ member: AnyTrainable) -> [AnyTrainable] { [member] }
    public static func buildExpression(_ members: [AnyTrainable]) -> [AnyTrainable] { members }
    public static func buildBlock(_ parts: [AnyTrainable]...) -> [AnyTrainable] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [AnyTrainable]?) -> [AnyTrainable] { part ?? [] }
    public static func buildEither(first part: [AnyTrainable]) -> [AnyTrainable] { part }
    public static func buildEither(second part: [AnyTrainable]) -> [AnyTrainable] { part }
    public static func buildArray(_ parts: [[AnyTrainable]]) -> [AnyTrainable] { parts.flatMap { $0 } }
}
