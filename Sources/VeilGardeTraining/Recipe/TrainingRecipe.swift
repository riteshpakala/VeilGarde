//
//  TrainingRecipe.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A training run as one declaration, written the way a SwiftUI body is: one model recipe
//        per line, `if` and `for` where the set depends on something. Each recipe is a value with
//        copy modifiers, so it reads top to bottom and builds nothing until the engine runs it.
//
//            let recipe = TrainingRecipe(id: "shipped-2026-10") {
//                WarpTileModel(dataset: finalMixed).shape(.deployed)
//                SensorCalibration().maxRealFPR(0.10).band(0.04)
//                FusionHead().warmStart(add: 80, eta: 0.03)
//                for kind in HeadKind.flywheelCategories { DinoHead(kind) }
//                Combiner().realsWeight(3)
//                if retrainNoiseprint { NoiseprintModel().epochs(6) }
//            }
//            let engine = TrainingEngine(area: area, parent: shippedBundle, store: storeDirectory)
//            for plan in try engine.plan(recipe) { print(plan.summary) }    // reads files, no MLX
//            let outcome = try engine.train(recipe)                         // writes candidates/<id>/
//
//  PIN:  Braid's ThreadRecipe / BraidBuilder pattern. The engine trains in dependency order
//        (warp tile model, calibration, fusion head, heads, combiner, noiseprint) whatever the
//        declaration order, because calibration reads the warp model and the combiner reads the
//        heads. The noiseprint reads images, not the store, and nothing reads it back: the
//        combiner takes its column from the store, and the flywheel never replaces it.
//

import Foundation
import VeilGardeCore

// MARK: The model recipes

/// The warp tile model, from a manifest's images through the tile cache.
public struct WarpTileModel: Sendable, Equatable, Codable {
    /// A dataset folder with final_mixed's manifest.csv, or a dataset.jsonl.
    public var dataset: URL
    public var shape: WarpShape = .deployed
    public var params: BoostParams
    /// At most this many images of each label (a quick run); nil takes them all.
    public var samplePerLabel: Int?
    public var sampleSeed: UInt64 = 0

    public init(dataset: URL) {
        self.dataset = dataset
        self.params = WarpShape.deployed.params
    }

    private func with(_ change: (inout WarpTileModel) -> Void) -> WarpTileModel { var c = self; change(&c); return c }
    public func shape(_ shape: WarpShape) -> WarpTileModel { with { $0.shape = shape; $0.params = shape.params } }
    public func trees(_ n: Int) -> WarpTileModel { with { $0.params.trees = n } }
    public func depth(_ d: Int) -> WarpTileModel { with { $0.params.maxDepth = d } }
    public func eta(_ e: Double) -> WarpTileModel { with { $0.params.eta = e } }
    public func seed(_ s: UInt64) -> WarpTileModel { with { $0.params.seed = s } }
    public func sample(perLabel n: Int, seed: UInt64 = 0) -> WarpTileModel { with { $0.samplePerLabel = n; $0.sampleSeed = seed } }
}

/// The camera-sensor score's Platt calibration, fitted on the tile cache's validation images.
public struct SensorCalibration: Sendable, Equatable, Codable {
    public var settings = CalibrationSettings()
    /// The dataset whose tile cache holds the validation images; nil takes the warp model's.
    public var dataset: URL?

    public init(dataset: URL? = nil) { self.dataset = dataset }

    private func with(_ change: (inout SensorCalibration) -> Void) -> SensorCalibration { var c = self; change(&c); return c }
    public func maxRealFPR(_ v: Double) -> SensorCalibration { with { $0.settings.maxRealFPR = v } }
    public func band(_ v: Double) -> SensorCalibration { with { $0.settings.band = v } }
}

/// The fusion head over the store's 397-value rows.
public struct FusionHead: Sendable, Equatable, Codable {
    public var settings = FusionSettings()

    public init() {}

    private func with(_ change: (inout FusionHead) -> Void) -> FusionHead { var c = self; change(&c); return c }
    public func warmStart(add: Int = 80, eta: Double = 0.03) -> FusionHead { with { $0.settings.mode = .warmStart(add: add, eta: eta) } }
    public func scratch(trees: Int = 500, eta: Double = 0.04) -> FusionHead { with { $0.settings.mode = .scratch(trees: trees, eta: eta) } }
    public func newGeneratorWeight(_ w: Double) -> FusionHead { with { $0.settings.newGeneratorWeight = w } }
    public func previewWeight(_ w: Double) -> FusionHead { with { $0.settings.previewWeight = w } }
    public func emphasize(_ ids: [String], weight: Double = 3) -> FusionHead { with { $0.settings.emphasize = ids; $0.settings.emphasizeWeight = weight } }
    public func allowMixedWarp(_ allow: Bool = true) -> FusionHead { with { $0.settings.allowMixedWarp = allow } }
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
    public func probes(_ p: [CombinerProbe]) -> Combiner { with { $0.settings.probes = p } }
}

/// The noiseprint CNN, from camera originals against everything that is not a capture.
public struct NoiseprintModel: Sendable, Equatable, Codable {
    public var settings = NoiseprintSettings()

    public init() {}

    private func with(_ change: (inout NoiseprintModel) -> Void) -> NoiseprintModel { var n = self; change(&n); return n }
    public func epochs(_ n: Int) -> NoiseprintModel { with { $0.settings.epochs = n } }
    public func batch(_ n: Int) -> NoiseprintModel { with { $0.settings.batch = n } }
    public func learningRate(_ r: Double) -> NoiseprintModel { with { $0.settings.learningRate = r } }
    public func perFamily(_ n: Int) -> NoiseprintModel { with { $0.settings.sources.perFamily = n } }
    public func sources(_ s: NoiseprintSources) -> NoiseprintModel { with { $0.settings.sources = s } }
    public func seed(_ s: UInt64) -> NoiseprintModel { with { $0.settings.seed = s } }
    public func cachePatches(_ on: Bool) -> NoiseprintModel { with { $0.settings.cachePatches = on } }
}

public enum ModelRecipe: Sendable, Equatable, Codable {
    case warpTile(WarpTileModel)
    case calibration(SensorCalibration)
    case fusion(FusionHead)
    case head(DinoHead)
    case combiner(Combiner)
    case noiseprint(NoiseprintModel)

    /// The slot it trains, as the plan names it.
    public var name: String {
        switch self {
        case .warpTile: return "warp-tile"
        case .calibration: return "sensor-calibration"
        case .fusion: return "fusion-head"
        case .head(let h): return "head:\(h.kind.rawValue)"
        case .combiner: return "combiner"
        case .noiseprint: return "noiseprint"
        }
    }

    /// Dependency order: warp, calibration, fusion, heads, combiner, noiseprint.
    var rank: Int {
        switch self {
        case .warpTile: return 0
        case .calibration: return 1
        case .fusion: return 2
        case .head: return 3
        case .combiner: return 4
        case .noiseprint: return 5
        }
    }
}

// MARK: The builder

@resultBuilder
public enum TrainingBuilder {
    public static func buildExpression(_ r: WarpTileModel) -> [ModelRecipe] { [.warpTile(r)] }
    public static func buildExpression(_ r: SensorCalibration) -> [ModelRecipe] { [.calibration(r)] }
    public static func buildExpression(_ r: FusionHead) -> [ModelRecipe] { [.fusion(r)] }
    public static func buildExpression(_ r: DinoHead) -> [ModelRecipe] { [.head(r)] }
    public static func buildExpression(_ r: Combiner) -> [ModelRecipe] { [.combiner(r)] }
    public static func buildExpression(_ r: NoiseprintModel) -> [ModelRecipe] { [.noiseprint(r)] }
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

    /// Every shipped model the store and a dataset can reproduce: the warp tile model in
    /// optimal_8's shape, its calibration as two cuts on the tile vote, a warm-started fusion head,
    /// the atlas heads, the preview head, and the combiner. No art-pair head: the shipped combiner no
    /// longer adjudicates the art head (the pruning study); DinoHead(.artPair) still trains one, and a
    /// combiner fitted beside it adjudicates again.
    public static func shipped(id: String, dataset: URL) -> TrainingRecipe {
        TrainingRecipe(id: id) {
            WarpTileModel(dataset: dataset).shape(.deployed)
            SensorCalibration()
            FusionHead().warmStart(add: 80, eta: 0.03)
            for kind in HeadKind.flywheelCategories { DinoHead(kind) }
            DinoHead(.preview)
            Combiner()
        }
    }
}
