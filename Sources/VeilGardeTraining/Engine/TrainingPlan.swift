//
//  TrainingPlan.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What training a recipe would do, before anything trains: per model, which stages run
//        and why, what it reads and what it will write, or why it is refused. A plan reads the
//        parent bundle and the store's row lists; it trains nothing, so it is cheap to ask for and
//        safe to show.
//

import Foundation
import VeilGardeCore

public enum TrainingStage: String, Codable, Sendable, CaseIterable {
    /// Read the training rows (the store's columns).
    case data
    /// Fit the model.
    case fit
    /// Measure it on held-out rows.
    case evaluate
    /// Write it, and its metrics, into the candidate bundle.
    case write
}

public struct StageDecision: Sendable, Equatable, Codable {
    public var stage: TrainingStage
    public var runs: Bool
    public var reason: String

    public init(_ stage: TrainingStage, runs: Bool, _ reason: String) {
        self.stage = stage
        self.runs = runs
        self.reason = reason
    }
}

public struct ModelPlan: Sendable, Equatable, Codable {
    public var model: String
    public var stages: [StageDecision]
    /// Why this model cannot be trained; a plan with a refusal stops the run before any work.
    public var refusal: String?
    public var notes: [String] = []

    public var summary: String {
        var lines = [model + (refusal.map { ": refused, \($0)" } ?? "")]
        for d in stages {
            lines.append("  " + d.stage.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0) + (d.runs ? "runs   " : "skips  ") + d.reason)
        }
        for note in notes { lines.append("  note     " + note) }
        return lines.joined(separator: "\n")
    }
}

public struct TrainingPlan: Sendable, Equatable {
    public var recipeID: String
    public var candidate: URL
    public var parent: URL
    public var store: URL
    public var models: [ModelPlan]

    public var refusals: [String] { models.compactMap { m in m.refusal.map { "\(m.model): \($0)" } } }

    public var summary: String {
        (["recipe \(recipeID) → \(candidate.path)", "  parent bundle  \(parent.path)", "  feature store  \(store.path)"]
            + models.map(\.summary)).joined(separator: "\n")
    }
}
