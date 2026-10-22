//
//  TrainingContext.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What a trainable member reads while it plans and while it trains. The context: the work
//        area, the parent bundle, the store's row lists and the whole recipe (so a member can say
//        whether another member of the same run trains what it reads). The run: the candidate
//        being written, the store's columns, the event log, and the selections members share.
//

import Foundation
import VeilGardeCore

public struct TrainingContext {
    public let area: WorkArea
    public let parentURL: URL
    /// The parent bundle, opened without re-hashing (a plan reads, never trusts, its bytes).
    public let parent: ModelBundle
    public let store: URL
    /// Every store row, from the meta lists (no columns).
    public let rows: [(shard: String, row: FeatureRow)]
    /// Why every member is refused, when the store holds no rows.
    public let storeMissing: String?
    public let recipe: TrainingRecipe

    /// Whether this recipe trains the member of that name.
    public func trains(_ name: String) -> Bool { recipe.members.contains { $0.member.name == name } }
}

public final class TrainingRun {
    public let context: TrainingContext
    /// The candidate this run writes; members replace their slot in it.
    public var candidate: CandidateBundle
    public let store: FeatureStore
    private let onEvent: (TrainingEvent) -> Void
    private var dinoNorm: StoreSelection?

    init(context: TrainingContext, candidate: CandidateBundle, store: FeatureStore, onEvent: @escaping (TrainingEvent) -> Void) {
        self.context = context
        self.candidate = candidate
        self.store = store
        self.onEvent = onEvent
    }

    public func emit(_ event: TrainingEvent) { onEvent(event) }

    /// Writes a metrics value beside the member's artifact and logs it; returns it as pretty JSON.
    public func record<T: Encodable>(_ value: T, model: String, as file: String) throws -> String {
        try candidate.write(value, as: file)
        let json = String(decoding: try JSONCoding.prettyEncoder().encode(value), as: UTF8.self)
        emit(.metrics(model: model, json: json))
        return json
    }

    /// The store's dino_norm column for every row, read once and shared by the linear heads.
    public func dinoNormSelection() throws -> StoreSelection {
        if let dinoNorm { return dinoNorm }
        let selection = try store.select(columns: [.dinoNorm])
        dinoNorm = selection
        return selection
    }
}
