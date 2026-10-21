//
//  TrainingRecipe.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A training run as one declaration, written the way a SwiftUI body is: one model recipe
//        per line, `if` and `for` where the set depends on something. Each recipe is a value with
//        copy modifiers, so it reads top to bottom and builds nothing until the engine runs it.
//
//            let recipe = TrainingRecipe(id: "fusion-2026-10") {
//                FusionHead().scratch(trees: 500, eta: 0.04)
//                for kind in HeadKind.flywheelCategories { DinoHead(kind) }
//                Combiner().realsWeight(3)
//            }
//            let engine = TrainingEngine(area: area, parent: shippedBundle, store: storeDirectory)
//            print(try engine.plan(recipe).summary)     // reads files, trains nothing
//            let outcome = try engine.train(recipe)     // writes candidates/<id>/
//
//  PIN:  Braid's ThreadRecipe / BraidBuilder pattern. The engine trains in dependency order
//        (fusion head, heads, combiner) whatever the declaration order, because the combiner reads
//        the fusion head and the heads. Every model trains on the features-only store.
//

import Foundation
import VeilGardeCore

// MARK: The model recipes

/// The fusion head over the store's 393-value rows.
public struct FusionHead: Sendable, Equatable, Codable {
    public var settings = FusionSettings()

    public init() {}

    private func with(_ change: (inout FusionHead) -> Void) -> FusionHead { var c = self; change(&c); return c }
    public func warmStart(add: Int = 80, eta: Double = 0.03) -> FusionHead { with { $0.settings.mode = .warmStart(add: add, eta: eta) } }
    public func scratch(trees: Int = 500, eta: Double = 0.04) -> FusionHead { with { $0.settings.mode = .scratch(trees: trees, eta: eta) } }
    public func newGeneratorWeight(_ w: Double) -> FusionHead { with { $0.settings.newGeneratorWeight = w } }
    public func previewWeight(_ w: Double) -> FusionHead { with { $0.settings.previewWeight = w } }
    public func emphasize(_ ids: [String], weight: Double = 3) -> FusionHead { with { $0.settings.emphasize = ids; $0.settings.emphasizeWeight = weight } }
    public func columns(_ layout: FusionLayout) -> FusionHead { with { $0.settings.layout = layout } }
    public func depth(_ d: Int) -> FusionHead { with { $0.settings.maxDepth = d } }
}

/// One specialist head over the store's dino_norm column.
public struct DinoHead: Sendable, Equatable, Codable {
    public var kind: HeadKind
    public var positives: RowFilter
    public var negatives: RowFilter
    public var settings = HeadSettings()

    /// The shipped recipe for `kind`.
    public init(_ kind: HeadKind) {
        self.kind = kind
        switch kind {
        case .art, .blur, .human, .cgi:
            positives = .generated(kind.rawValue); negatives = .allReal
        case .preview:
            positives = .generated("preview"); negatives = .real("preview"); settings.admission = false
        case .artPair:
            positives = .generated("art"); negatives = .real("art"); settings.classWeight = .none; settings.admission = false; settings.fireThreshold = nil
        case .screenshot:
            positives = .generated("screenshot"); negatives = .real("screenshot"); settings.C = 1.0; settings.classWeight = .none
            settings.admission = false; settings.fireThreshold = nil
        case .semtile:
            positives = .generated("art"); negatives = .allReal; settings.admission = false
        }
    }

    private func with(_ change: (inout DinoHead) -> Void) -> DinoHead { var c = self; change(&c); return c }
    public func positives(_ f: RowFilter) -> DinoHead { with { $0.positives = f } }
    public func negatives(_ f: RowFilter) -> DinoHead { with { $0.negatives = f } }
    public func regularization(C: Double) -> DinoHead { with { $0.settings.C = C } }
    public func balanced(_ on: Bool = true) -> DinoHead { with { $0.settings.classWeight = on ? .balanced : .none } }
    public func version(_ v: String) -> DinoHead { with { $0.settings.version = v } }
    public func admission(_ on: Bool) -> DinoHead { with { $0.settings.admission = on } }
}

/// The stack combiner over the candidate's base and heads.
public struct Combiner: Sendable, Equatable, Codable {
    public var settings = CombinerSettings()

    public init() {}

    private func with(_ change: (inout Combiner) -> Void) -> Combiner { var c = self; change(&c); return c }
    public func realsWeight(_ w: Double) -> Combiner { with { $0.settings.realsWeight = w } }
    /// Fit on out-of-fold base predictions, `folds` heads refit each without one fold.
    public func outOfFold(folds: Int = 5) -> Combiner { with { $0.settings.baseFolds = folds } }
    public func probes(_ p: [CombinerProbe]) -> Combiner { with { $0.settings.probes = p } }
}

public enum ModelRecipe: Sendable, Equatable, Codable {
    case fusion(FusionHead)
    case head(DinoHead)
    case combiner(Combiner)

    /// The slot it trains, as the plan names it.
    public var name: String {
        switch self {
        case .fusion: return "fusion-head"
        case .head(let h): return "head:\(h.kind.rawValue)"
        case .combiner: return "combiner"
        }
    }

    /// Dependency order: fusion, heads, combiner.
    var rank: Int {
        switch self {
        case .fusion: return 0
        case .head: return 1
        case .combiner: return 2
        }
    }
}

// MARK: The builder

@resultBuilder
public enum TrainingBuilder {
    public static func buildExpression(_ r: FusionHead) -> [ModelRecipe] { [.fusion(r)] }
    public static func buildExpression(_ r: DinoHead) -> [ModelRecipe] { [.head(r)] }
    public static func buildExpression(_ r: Combiner) -> [ModelRecipe] { [.combiner(r)] }
    public static func buildExpression(_ r: ModelRecipe) -> [ModelRecipe] { [r] }
    public static func buildExpression(_ r: [ModelRecipe]) -> [ModelRecipe] { r }
    public static func buildBlock(_ parts: [ModelRecipe]...) -> [ModelRecipe] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [ModelRecipe]?) -> [ModelRecipe] { part ?? [] }
    public static func buildEither(first part: [ModelRecipe]) -> [ModelRecipe] { part }
    public static func buildEither(second part: [ModelRecipe]) -> [ModelRecipe] { part }
    public static func buildArray(_ parts: [[ModelRecipe]]) -> [ModelRecipe] { parts.flatMap { $0 } }
}

public struct TrainingRecipe: Sendable, Equatable, Codable {
    public var id: String
    public var models: [ModelRecipe]

    public init(id: String, @TrainingBuilder _ content: () throws -> [ModelRecipe]) rethrows {
        self.id = id
        self.models = try content()
    }

    public init(id: String, models: [ModelRecipe]) {
        self.id = id
        self.models = models
    }

    /// The models in the order they train.
    public var ordered: [ModelRecipe] {
        models.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element)
    }

    /// Every shipped model the store reproduces: the fusion head from scratch over DINOv2 and
    /// capture, the flywheel's category heads, the preview head, and the combiner. No art-pair head
    /// (its adjudication left the shipped combiner on 2026-10-19) and no cgi head (its only reader,
    /// the render arbiter, left on 2026-10-21); DinoHead(.artPair) and DinoHead(.cgi) still train.
    public static func shipped(id: String) -> TrainingRecipe {
        TrainingRecipe(id: id) {
            FusionHead().scratch(trees: 500, eta: 0.04)
            for kind in HeadKind.flywheelCategories { DinoHead(kind) }
            DinoHead(.preview)
            Combiner()
        }
    }
}
