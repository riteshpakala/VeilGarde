//
//  TrainingEngine.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Trains recipes into candidate bundles. `plan` asks every member what it would do and
//        trains nothing; `train` plans first (so a refusal stops the run before any work), seeds
//        <work area>/candidates/<id>/ from the parent bundle, then has each member train in
//        dependency order and write itself in place of the parent's.
//  PIN:  Every fit is CPU arithmetic on the features-only store (no MLX). The parent bundle is
//        opened read-only and verified (every hash) before it is copied. A member a recipe does not
//        name stays the parent's. The engine knows no member by name: it loops.
//

import Foundation
import VeilGardeCore

public struct TrainingOutcome: Sendable {
    public var candidate: CandidateBundle
    /// Per member, its metrics as written (pretty JSON).
    public var metrics: [String: String]
    public var seconds: Double
}

public final class TrainingEngine {
    public let area: WorkArea
    public let parent: URL
    public let store: URL
    public var replace = false
    private let onEvent: (TrainingEvent) -> Void
    private var log: JSONLWriter?
    private var storeRows: [(shard: String, row: FeatureRow)]?

    public init(area: WorkArea, parent: URL, store: URL? = nil, onEvent: @escaping (TrainingEvent) -> Void = { _ in }) {
        self.area = area
        self.parent = parent
        self.store = store ?? area.root.appendingPathComponent("store/shards", isDirectory: true)
        self.onEvent = onEvent
    }

    /// The store's rows, from its meta lists (no columns).
    func rows() throws -> [(shard: String, row: FeatureRow)] {
        if let storeRows { return storeRows }
        let s = FeatureStore(directory: store)
        var out: [(String, FeatureRow)] = []
        for name in s.shardNames() { out += try FeatureShard.readRows(name, in: store).map { (name, $0) } }
        storeRows = out
        return out
    }

    func context(_ recipe: TrainingRecipe) throws -> TrainingContext {
        guard !recipe.id.isEmpty, !recipe.id.contains("/"), !recipe.id.hasPrefix(".") else {
            throw VeilGardeFailure.usage("a recipe id is one path component: \(recipe.id)")
        }
        var seen = Set<String>()
        for m in recipe.ordered where !seen.insert(m.name).inserted { throw VeilGardeFailure.usage("\(m.name) appears twice in the recipe") }
        let rows = !recipe.members.isEmpty && FileManager.default.fileExists(atPath: store.path) ? try self.rows() : []
        return TrainingContext(area: area, parentURL: parent, parent: try ModelBundle.load(parent, verify: false), store: store, rows: rows,
                               storeMissing: !recipe.members.isEmpty && rows.isEmpty ? "the feature store at \(store.path) holds no rows" : nil,
                               recipe: recipe)
    }

    public func plan(_ recipe: TrainingRecipe) throws -> TrainingPlan {
        let context = try self.context(recipe)
        return TrainingPlan(recipeID: recipe.id, candidate: area.root.appendingPathComponent("candidates/\(recipe.id)"), parent: parent,
                            store: store, models: try recipe.ordered.map { try $0.plan(in: context) })
    }

    @discardableResult
    public func train(_ recipe: TrainingRecipe) throws -> TrainingOutcome {
        let started = Date()
        let plan = try self.plan(recipe)
        if !plan.refusals.isEmpty { throw VeilGardeFailure.usage("the recipe is refused:\n  " + plan.refusals.joined(separator: "\n  ")) }
        let candidate = try CandidateBundle.create(id: recipe.id, in: area, from: try ModelBundle.load(parent), replacing: replace)
        try candidate.write(recipe, as: "recipe.json")
        log = try JSONLWriter(url: candidate.root.appendingPathComponent("runs.jsonl"), truncate: true)
        defer { log = nil }
        emit(.note("training \(recipe.id) into \(candidate.root.path)"))
        let run = TrainingRun(context: try context(recipe), candidate: candidate, store: FeatureStore(directory: store)) { [weak self] in self?.emit($0) }
        var metrics: [String: String] = [:]
        for member in recipe.ordered { metrics[member.name] = try member.train(in: run) }
        try run.candidate.verify()
        let seconds = Date().timeIntervalSince(started)
        emit(.note(String(format: "candidate %@ verified (%d artifacts) in %.1fs", recipe.id, run.candidate.manifest.artifacts.count, seconds)))
        return TrainingOutcome(candidate: run.candidate, metrics: metrics, seconds: seconds)
    }

    private func emit(_ event: TrainingEvent) {
        onEvent(event)
        try? log?.append(event.row)
    }
}
