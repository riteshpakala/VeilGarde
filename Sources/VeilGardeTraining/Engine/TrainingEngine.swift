//
//  TrainingEngine.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Trains recipes into candidate bundles. `plan` says what training would do and trains
//        nothing; `train` plans first (so a refusal stops the run before any work), seeds
//        <work area>/candidates/<id>/ from the parent bundle, then trains each model in dependency
//        order and writes it in place of the parent's: the fusion head, the heads, the combiner.
//  PIN:  Every fit is CPU arithmetic on the features-only store (no MLX). The parent bundle is
//        opened read-only and verified (every hash) before it is copied. A model a recipe does not
//        name stays the parent's. A warm start needs a parent fusion head of the store's width.
//

import Foundation
import VeilGardeCore

public struct TrainingOutcome: Sendable {
    public var candidate: CandidateBundle
    /// Per model, its metrics as written (pretty JSON).
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
    /// The settings of the fusion head this run trained, for an out-of-fold combiner.
    private var trainedFusion: FusionSettings?

    public init(area: WorkArea, parent: URL, store: URL? = nil, onEvent: @escaping (TrainingEvent) -> Void = { _ in }) {
        self.area = area
        self.parent = parent
        self.store = store ?? area.root.appendingPathComponent("store/shards", isDirectory: true)
        self.onEvent = onEvent
    }

    // MARK: Inputs

    /// The store's rows, from its meta lists (no columns).
    func rows() throws -> [(shard: String, row: FeatureRow)] {
        if let storeRows { return storeRows }
        let s = FeatureStore(directory: store)
        var out: [(String, FeatureRow)] = []
        for name in s.shardNames() {
            let rows = try JSONDecoder().decode([FeatureRow].self, from: Data(contentsOf: FeatureShard.metaURL(store, name)))
            out += rows.map { (name, $0) }
        }
        storeRows = out
        return out
    }

    // MARK: Plans

    public func plan(_ recipe: TrainingRecipe) throws -> TrainingPlan {
        guard !recipe.id.isEmpty, !recipe.id.contains("/"), !recipe.id.hasPrefix(".") else {
            throw VeilGardeFailure.usage("a recipe id is one path component: \(recipe.id)")
        }
        let parentBundle = try ModelBundle.load(parent, verify: false)
        let ordered = recipe.ordered
        var seen = Set<String>()
        for m in ordered where !seen.insert(m.name).inserted { throw VeilGardeFailure.usage("\(m.name) appears twice in the recipe") }
        let trainsFusion = ordered.contains { if case .fusion = $0 { return true } else { return false } }
        let trainedHeads = Set(ordered.compactMap { if case .head(let h) = $0 { return h.kind } else { return nil } })
        let storeRows = !ordered.isEmpty && FileManager.default.fileExists(atPath: store.path) ? try rows() : []
        let storeMissing = !ordered.isEmpty && storeRows.isEmpty ? "the feature store at \(store.path) holds no rows" : nil
        var plans: [ModelPlan] = []

        for model in ordered {
            switch model {
            case .fusion(let f):
                var p = ModelPlan(model: model.name, stages: [], refusal: storeMissing)
                let usable = storeRows.filter { !$0.row.golden && !$0.row.nsfw }
                let newGen = usable.filter { r in r.row.isGenerated && f.settings.newGeneratorShards.contains { r.shard.hasPrefix($0) } }.count
                let parentWidth: Int? = parentBundle.manifest.artifact(.fusionHead).flatMap {
                    try? GBDTModel.load(parentBundle.root.appendingPathComponent($0.file)).featureCount
                }
                let layout = f.settings.resolvedLayout
                let mode: String
                switch f.settings.mode {
                case .warmStart(let add, let eta):
                    mode = "warm start: +\(add) trees at η \(eta) onto the parent's fusion head \(parentBundle.sha256(.fusionHead)?.prefix(12) ?? "?")"
                    if let w = parentWidth, w != layout.width {
                        p.refusal = "the parent's fusion head reads \(w) features, the recipe's fusion rows \(layout.width): train it from scratch"
                    }
                case .scratch(let trees, let eta):
                    mode = "from scratch: \(trees) trees at η \(eta)"
                    if let w = parentWidth, w != layout.width {
                        p.notes.append("the parent's fusion head reads \(w) features: no parent recall or agreement will be reported")
                    }
                }
                p.stages = [
                    StageDecision(.data, runs: true, "\(usable.count) store rows that are not golden or NSFW (those carrying dino_fusion), \(newGen) of them new-generator rows; \(layout.width) columns, \(layout.columns.map(\.rawValue).joined(separator: ", "))"),
                    StageDecision(.fit, runs: true, mode + ", depth \(f.settings.maxDepth), subsample \(f.settings.subsample), colsample \(f.settings.colsample)"),
                    StageDecision(.evaluate, runs: true, "recall on the \(Int(f.settings.holdoutFraction * 100))% of new-generator rows held out, agreement with the parent when it reads the same columns, and an evaluation twin's AUC on a \(Int(f.settings.evaluationFraction * 100))% hash holdout"),
                    StageDecision(.write, runs: true, "fusion/fusion_head.xgb.json"),
                ]
                plans.append(p)

            case .head(let h):
                var p = ModelPlan(model: model.name, stages: [], refusal: storeMissing)
                let categories = Set(storeRows.map(\.row.category))
                if let reason = HeadTrainer.refusal(h.kind, categories: categories) { p.refusal = reason }
                let usable = storeRows.filter { !$0.row.golden }
                let pos = usable.filter { h.positives.matches($0.row) }.count
                let neg = usable.filter { !h.positives.matches($0.row) && h.negatives.matches($0.row) }.count
                p.stages = [
                    StageDecision(.data, runs: true, "\(pos) positives (\(h.positives.summary)) and \(neg) negatives (\(h.negatives.summary)), golden held out, those carrying dino_norm"),
                    StageDecision(.fit, runs: true, "StandardScaler and logistic regression, C \(h.settings.C), class weight \(h.settings.classWeight.rawValue)"),
                    StageDecision(.evaluate, runs: true, "test AUC on the source-disjoint 25% split; golden-real anchors' block at 0.5 and 0.8"
                                  + (h.settings.admission ? "; admission at block@0.8 ≤ 0.10" : "")),
                    StageDecision(.write, runs: true, "heads/\(h.kind.rawValue)/head.json"),
                ]
                plans.append(p)

            case .combiner(let c):
                var p = ModelPlan(model: model.name, stages: [], refusal: storeMissing)
                var base = trainsFusion ? "the fusion head this recipe trains" : "the parent's fusion head"
                if let folds = c.settings.baseFolds {
                    let fusionRecipe = ordered.compactMap { if case .fusion(let f) = $0 { return f } else { return nil } }.first
                    switch outOfFoldSource(folds: folds, recipeFusion: fusionRecipe?.settings, parentBundle: parentBundle) {
                    case .some(let source): base += ", out-of-fold over \(folds) folds (\(source))"
                    case .none: p.refusal = "an out-of-fold combiner needs the fusion head's settings: train a scratch fusion head in the same recipe, or name a parent candidate that trained one"
                    }
                }
                // An art-pair head joins only when the recipe trains one or the parent carries one; the shipped bundle does not.
                let pairHere = trainedHeads.contains(.artPair) || parentBundle.url(.head, head: .artPair) != nil
                let heads = ([HeadKind.art, .blur, .human] + (pairHere ? [.artPair] : [])).map { trainedHeads.contains($0) ? "\($0.rawValue) (trained)" : "\($0.rawValue) (parent)" }.joined(separator: ", ")
                p.stages = [
                    StageDecision(.data, runs: true, "capture-absent store rows (not golden or NSFW): base from \(base); heads \(heads)"),
                    StageDecision(.fit, runs: true, "non-negative logistic, reals ×\(c.settings.realsWeight.formatted()), the rescue column zeroed (combiner v3)"),
                    StageDecision(.evaluate, runs: true, "the rescue sweep against \(CombinerProbe.userReals.count) protect-real probes; test AUC beside the base"),
                    StageDecision(.write, runs: true, "combiner/stack_combiner.json"),
                ]
                plans.append(p)

            }
        }
        return TrainingPlan(recipeID: recipe.id, candidate: area.root.appendingPathComponent("candidates/\(recipe.id)"), parent: parent,
                            store: store, models: plans)
    }

    // MARK: Training

    @discardableResult
    public func train(_ recipe: TrainingRecipe) throws -> TrainingOutcome {
        let started = Date()
        let plan = try self.plan(recipe)
        if !plan.refusals.isEmpty { throw VeilGardeFailure.usage("the recipe is refused:\n  " + plan.refusals.joined(separator: "\n  ")) }
        var candidate = try CandidateBundle.create(id: recipe.id, in: area, from: try ModelBundle.load(parent), replacing: replace)
        try candidate.write(recipe, as: "recipe.json")
        log = try JSONLWriter(url: candidate.root.appendingPathComponent("runs.jsonl"), truncate: true)
        defer { log = nil }
        emit(.note("training \(recipe.id) into \(candidate.root.path)"))
        var metrics: [String: String] = [:]
        for model in recipe.ordered {
            switch model {
            case .fusion(let f):
                metrics[model.name] = try trainFusion(f, into: &candidate)
            case .head(let h):
                metrics[model.name] = try trainHead(h, into: &candidate)
            case .combiner(let c):
                metrics[model.name] = try trainCombiner(c, into: &candidate)
            }
        }
        try candidate.verify()
        let seconds = Date().timeIntervalSince(started)
        emit(.note(String(format: "candidate %@ verified (%d artifacts) in %.1fs", recipe.id, candidate.manifest.artifacts.count, seconds)))
        return TrainingOutcome(candidate: candidate, metrics: metrics, seconds: seconds)
    }

    private func emit(_ event: TrainingEvent) {
        onEvent(event)
        try? log?.append(event.row)
    }

    private func record<T: Encodable>(_ value: T, model: String, as file: String, in candidate: CandidateBundle) throws -> String {
        try candidate.write(value, as: file)
        let json = String(decoding: try JSONCoding.prettyEncoder().encode(value), as: UTF8.self)
        emit(.metrics(model: model, json: json))
        return json
    }

    // MARK: Fusion

    struct FusionMetrics: Codable {
        var settings: FusionSettings
        var parentSHA256: String?
        var report: FusionReport
    }

    private func trainFusion(_ f: FusionHead, into candidate: inout CandidateBundle) throws -> String {
        let name = "fusion-head"
        trainedFusion = f.settings
        emit(.stage(model: name, .data))
        let dataset = try FusionDataset.assemble(FeatureStore(directory: store), settings: f.settings)
        let parentArtifact = candidate.manifest.artifact(.fusionHead)
        let parentModel = try parentArtifact.map { try GBDTModel.load(candidate.root.appendingPathComponent($0.file)) }
        emit(.stage(model: name, .fit))
        let (model, report) = try FusionTrainer.train(dataset, settings: f.settings, parent: parentModel, note: { self.emit(.note($0)) })
        emit(.stage(model: name, .evaluate))
        emit(.note("fusion: held-out new-generator recall " + [report.heldOutRecallParent, report.heldOutRecallCandidate]
            .map { $0.map { String(format: "%.3f", $0) } ?? "n/a" }.joined(separator: " (parent) → ") + " (candidate)"
            + (report.agreementWithParent.map { String(format: ", agreement %.4f", $0) } ?? "")
            + (report.evaluationAUC.map { String(format: "; the evaluation twin's AUC %.4f on %d held-out rows", $0, report.evaluationRows) } ?? "")))
        emit(.stage(model: name, .write))
        let isWarm: Bool
        if case .warmStart = f.settings.mode { isWarm = true } else { isWarm = false }
        try candidate.put(model.encodeXGBoostJSON(), as: "fusion/fusion_head.xgb.json", role: .fusionHead,
                          parent: isWarm ? parentArtifact?.sha256 : nil)
        return try record(FusionMetrics(settings: f.settings, parentSHA256: parentArtifact?.sha256, report: report), model: name,
                          as: "fusion/metrics.json", in: candidate)
    }

    // MARK: Heads

    private var headSelection: StoreSelection?

    private func trainHead(_ h: DinoHead, into candidate: inout CandidateBundle) throws -> String {
        let name = "head:\(h.kind.rawValue)"
        emit(.stage(model: name, .data))
        if headSelection == nil { headSelection = try FeatureStore(directory: store).select(columns: [.dinoNorm]) }
        emit(.stage(model: name, .fit))
        let parentHead = try candidate.url(.head, head: h.kind).map { try LinearHead.load($0) }
        let (file, report) = try HeadTrainer.train(h.kind, positives: h.positives, negatives: h.negatives, settings: h.settings,
                                                   store: headSelection!, parent: parentHead, note: { self.emit(.note($0)) })
        emit(.stage(model: name, .evaluate))
        func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a" }
        emit(.note(String(format: "head %@: test AUC %.4f (split by %@); golden-real block@0.8 %@", h.kind.rawValue, report.testAUC,
                          report.split.rawValue, pct(report.anchorBlock08))
            + (report.admitted.map { ($0 ? ", admitted" : ", NOT admitted") + " (block@0.8 \(pct(report.admissionBlock08)) on \(report.admissionAnchors) non-bsky golden reals, bar 10%)" } ?? "")
            + (report.parent.map { String(format: "; the parent's head on the same rows: test AUC %.4f, golden-real block@0.8 %@, admission block %@",
                                          $0.testAUC, pct($0.anchorBlock08), pct($0.admissionBlock08)) } ?? "")))
        emit(.stage(model: name, .write))
        let folder = "heads/\(h.kind.rawValue)"
        try candidate.put(try JSONCoding.prettyEncoder().encode(file), as: "\(folder)/head.json", role: .head, head: h.kind)
        try candidate.write(h, as: "\(folder)/recipe.json")
        return try record(report, model: name, as: "\(folder)/metrics.json", in: candidate)
    }

    // MARK: Combiner

    private func trainCombiner(_ c: Combiner, into candidate: inout CandidateBundle) throws -> String {
        let name = "combiner"
        emit(.stage(model: name, .data))
        guard let fusionURL = candidate.url(.fusionHead) else { throw VeilGardeFailure.missing("the candidate has no fusion head") }
        let base = try GBDTModel.load(fusionURL)
        func head(_ kind: HeadKind) throws -> LinearHead {
            guard let url = candidate.url(.head, head: kind) else { throw VeilGardeFailure.missing("the candidate has no \(kind.rawValue) head") }
            return try LinearHead.load(url)
        }
        let heads = try [HeadKind.art, .blur, .human].map(head)
        let pair = try? head(.artPair)
        let selection = try FeatureStore(directory: store).select(columns: Set(FeatureColumn.allCases)) { !$0.golden && !$0.nsfw }
        let samples: [CombinerSample]
        if let folds = c.settings.baseFolds {
            let oof = try outOfFoldBase(folds: folds, candidate: candidate)
            samples = CombinerSample.captureAbsent(selection, outOfFold: oof.predictions, heads: heads, pair: pair)
            emit(.note("combiner: \(samples.count) capture-absent rows with an out-of-fold base, \(folds) folds"))
        } else {
            samples = try CombinerSample.captureAbsent(selection, base: base, heads: heads, pair: pair)
        }
        emit(.stage(model: name, .fit))
        let (file, report) = try CombinerTrainer.train(samples, settings: c.settings, note: { self.emit(.note($0)) })
        emit(.stage(model: name, .evaluate))
        emit(.note(String(format: "combiner: w_base %.3f, w_gen [%@], w_rescue %.1f", file.wBase,
                          file.wGen.map { String(format: "%.3f", $0) }.joined(separator: ", "), file.wRescue)))
        emit(.stage(model: name, .write))
        try candidate.put(try JSONCoding.prettyEncoder().encode(file), as: "combiner/stack_combiner.json", role: .combiner)
        return try record(report, model: name, as: "combiner/metrics.json", in: candidate)
    }

    // MARK: Out-of-fold base predictions

    /// Where an out-of-fold combiner's base predictions come from, or nil when nothing can make them.
    func outOfFoldSource(folds: Int, recipeFusion: FusionSettings?, parentBundle: ModelBundle) -> String? {
        if let f = recipeFusion { return isScratch(f) ? "refit with the recipe's fusion settings" : nil }
        let headSHA = parentBundle.sha256(.fusionHead)
        if let cached = try? JSONCoding.read(OutOfFoldBase.self, from: parent.appendingPathComponent(OutOfFoldBase.file)),
           cached.folds == folds, cached.headSHA256 == headSHA { return "the parent's cached predictions" }
        if let m = try? JSONCoding.read(FusionMetrics.self, from: parent.appendingPathComponent("fusion/metrics.json")), isScratch(m.settings) {
            return "refit with the parent's fusion settings"
        }
        return nil
    }

    private func isScratch(_ f: FusionSettings) -> Bool { if case .scratch = f.mode { return true } else { return false } }

    /// The candidate's out-of-fold base predictions: cached in the candidate or its parent for the
    /// same head and folds, else refit and cached in the candidate.
    private func outOfFoldBase(folds: Int, candidate: CandidateBundle) throws -> OutOfFoldBase {
        guard let headSHA = candidate.manifest.artifact(.fusionHead)?.sha256 else { throw VeilGardeFailure.missing("the candidate has no fusion head") }
        for root in [candidate.root, parent] {
            if let cached = try? JSONCoding.read(OutOfFoldBase.self, from: root.appendingPathComponent(OutOfFoldBase.file)),
               cached.folds == folds, cached.headSHA256 == headSHA {
                emit(.note("combiner: the out-of-fold base predictions cached in \(root.lastPathComponent), \(cached.predictions.count) rows"))
                if root != candidate.root { try candidate.write(cached, as: OutOfFoldBase.file) }
                return cached
            }
        }
        let settings: FusionSettings
        if let f = trainedFusion { settings = f } else if let m = try? JSONCoding.read(FusionMetrics.self, from: parent.appendingPathComponent("fusion/metrics.json")) {
            settings = m.settings
        } else {
            throw VeilGardeFailure.missing("an out-of-fold combiner needs the fusion head's settings", hint: "train the fusion head in the same recipe, or name a parent candidate that trained one")
        }
        let dataset = try FusionDataset.assemble(FeatureStore(directory: store), settings: settings)
        let predictions = try FusionTrainer.outOfFold(dataset, settings: settings, folds: folds, note: { self.emit(.note($0)) })
        let oof = OutOfFoldBase(folds: folds, headSHA256: headSHA, settings: settings, predictions: predictions)
        try candidate.write(oof, as: OutOfFoldBase.file)
        return oof
    }
}
