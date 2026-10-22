//
//  TrainableMember.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A trainable member of the stack, as a recipe declares it: a value with copy modifiers that
//        says what it would train (its plan) and trains it into a candidate (its run). The engine
//        loops over a recipe's members in dependency order and asks each; it knows none of them by
//        name. A new trainable member is one file conforming to this and one line in a recipe.
//  PIN:  `recipeKind` names the member's type in recipe.json; TrainingRecipe.kinds lists the types
//        a recipe file may name. `name` is the slot it trains as the plan, the metrics and the
//        manifest name it ("camera", "head:art", "combiner"); `rank` is its dependency order (the
//        combiner reads the heads and the camera head, so it trains last).
//

import Foundation
import VeilGardeCore

public protocol TrainableMember: Codable, Sendable {
    /// The member's type in recipe.json.
    static var recipeKind: String { get }
    /// The slot it trains: "camera", "head:<kind>", "combiner".
    var name: String { get }
    /// Dependency order: lower trains first.
    var rank: Int { get }
    /// What training it would do, reading only the parent and the store's row lists.
    func plan(in context: TrainingContext) throws -> ModelPlan
    /// Trains it into the run's candidate and returns the metrics it recorded.
    func train(in run: TrainingRun) throws -> String
}

/// A member in a recipe, its type erased so a recipe is one list and still round-trips as JSON:
/// {"kind": "<recipeKind>", "member": {…}}.
public struct AnyTrainable: Codable, Sendable, Equatable {
    public let member: any TrainableMember

    public init(_ member: some TrainableMember) { self.member = member }
    public init(erasing member: any TrainableMember) { self.member = member }

    public var kind: String { type(of: member).recipeKind }

    enum CodingKeys: String, CodingKey { case kind, member }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        guard let type = TrainingRecipe.kind(named: kind) else {
            let known = TrainingRecipe.kindNames.joined(separator: ", ")
            throw VeilGardeFailure.data("recipe.json names a member kind \(kind) this build does not train; it trains \(known)")
        }
        member = try type.init(from: c.superDecoder(forKey: .member))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try member.encode(to: c.superEncoder(forKey: .member))
    }

    /// Equal when the kind and the member's sorted JSON are equal.
    public static func == (a: AnyTrainable, b: AnyTrainable) -> Bool {
        guard a.kind == b.kind else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(a)) == (try? encoder.encode(b))
    }
}
