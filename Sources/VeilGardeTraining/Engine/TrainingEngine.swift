//
//  TrainingEngine.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Trains recipes into candidate bundles. `plan` says what training would do and touches
//        no MLX; `train` plans first (so a refusal stops the run before any work), seeds
//        <work area>/candidates/<id>/ from the parent bundle, then trains each model in
//        dependency order and writes it in place of the parent's: the warp tile model (and its
//        sensor copy), its calibration, the fusion head, the heads, the combiner, the noiseprint
//        (a weight file the candidate carries, its manifest's weight entry re-pinned to it).
//  PIN:  One MLX workload at a time: the tile cut and the noiseprint's training and test run on
//        the GPU, on the calling thread; every other fit is CPU arithmetic on stored features. The parent bundle is opened
//        read-only and verified (every hash) before it is copied. A model a recipe does not name
//        stays the parent's; a warp model retrained without its calibration drops the parent's
//        contract, which is bound to the old bytes, and the sensor lane falls back to identity.
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

    public init(area: WorkArea, parent: URL, store: URL? = nil, onEvent: @escaping (TrainingEvent) -> Void = { _ in }) {
        self.area = area
        self.parent = parent
        self.store = store ?? area.root.appendingPathComponent("store/shards", isDirectory: true)
        self.onEvent = onEvent
    }

    // MARK: Inputs

    /// The tile cache a dataset's images are cut into.
    public func tileCache(for dataset: URL) -> TileCache {
        let key = dataset.hasDirectoryPath || dataset.pathExtension.isEmpty ? dataset.lastPathComponent : dataset.deletingPathExtension().lastPathComponent
        return TileCache(directory: area.root.appendingPathComponent("store/tiles/\(key)", isDirectory: true))
    }

    /// A dataset as a manifest: a folder with final_mixed's manifest.csv, or a dataset.jsonl.
    public func manifest(for dataset: URL, samplePerLabel: Int? = nil, seed: UInt64 = 0) throws -> ImageManifest {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dataset.path, isDirectory: &isDirectory) else {
            throw VeilGardeFailure.missing("no dataset at \(dataset.path)")
        }
        var manifest = isDirectory.boolValue ? try ImageManifest.finalMixed(dataset) : try ImageManifest.load(dataset)
        manifest = manifest.withSplits()
        if let n = samplePerLabel { manifest = manifest.sample(perLabel: n, seed: seed) }
        return manifest
    }

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
        let warp = ordered.compactMap { if case .warpTile(let w) = $0 { return w } else { return nil } }.first
        let trainsFusion = ordered.contains { if case .fusion = $0 { return true } else { return false } }
        let trainedHeads = Set(ordered.compactMap { if case .head(let h) = $0 { return h.kind } else { return nil } })
        let needsStore = ordered.contains { switch $0 { case .fusion, .head, .combiner: return true; default: return false } }
        let storeRows = needsStore && FileManager.default.fileExists(atPath: store.path) ? try rows() : []
        let storeMissing = needsStore && storeRows.isEmpty ? "the feature store at \(store.path) holds no rows" : nil
        var plans: [ModelPlan] = []

        for model in ordered {
            switch model {
            case .warpTile(let w):
                var p = ModelPlan(model: model.name, stages: [], refusal: nil)
                do {
                    let manifest = try self.manifest(for: w.dataset, samplePerLabel: w.samplePerLabel, seed: w.sampleSeed)
                    let cache = tileCache(for: w.dataset)
                    let cached = (try? cache.stems()) ?? []
                    let pending = manifest.records.filter { !cached.contains($0.stem) }.count
                    let counts = Partition.allCases.map { part in "\(manifest.records(in: part).count) \(part.rawValue)" }.joined(separator: ", ")
                    p.stages = [
                        StageDecision(.tiles, runs: pending > 0, pending > 0 ? "cut \(pending) of \(manifest.count) images into \(cache.directory.path)" : "all \(manifest.count) images are cached"),
                        StageDecision(.data, runs: true, "the tiles of \(manifest.count) images: \(counts) (StableSplit by stem)"),
                        StageDecision(.fit, runs: true, "\(w.shape.rawValue): \(w.params.trees) trees, depth \(w.params.maxDepth), η \(w.params.eta), subsample \(w.params.subsample), colsample \(w.params.colsampleByTree)"
                                      + (w.params.earlyStoppingRounds.map { ", early stop \($0)" } ?? "")),
                        StageDecision(.evaluate, runs: true, "tile AUC and per-image weighted and majority AUC on validation and test, beside the parent's warp model"),
                        StageDecision(.write, runs: true, "warp/warp_tile32.xgb.json, and the same bytes as the sensor model"),
                    ]
                    if !ordered.contains(where: { if case .calibration = $0 { return true } else { return false } }) {
                        p.notes.append("the parent's calibration is bound to its warp bytes; it is dropped and the sensor lane falls back to identity (add SensorCalibration() to refit it)")
                    }
                } catch { p.refusal = "\(error)" }
                plans.append(p)

            case .calibration(let c):
                var p = ModelPlan(model: model.name, stages: [], refusal: nil)
                guard let dataset = c.dataset ?? warp?.dataset else {
                    p.refusal = "calibration needs the validation images of a dataset: name one, or train the warp tile model in the same recipe"
                    plans.append(p); continue
                }
                let sensor = warp != nil ? "the warp model this recipe trains" : "the parent's sensor model \(parentBundle.sha256(.warpMajoritySensor)?.prefix(12) ?? "?")"
                do {
                    let manifest = try self.manifest(for: dataset, samplePerLabel: warp?.samplePerLabel, seed: warp?.sampleSeed ?? 0)
                    let cached = (try? tileCache(for: dataset).stems()) ?? []
                    let pending = warp == nil ? manifest.records.filter { !cached.contains($0.stem) }.count : 0
                    let validation = manifest.records(in: .val).count
                    p.stages = [
                        StageDecision(.tiles, runs: pending > 0, pending > 0 ? "cut \(pending) images into the tile cache" : "the validation images' tiles are cached or cut by the warp step"),
                        StageDecision(.data, runs: true, "the majority fraction of \(validation) validation images under \(sensor)"),
                        StageDecision(.fit, runs: true, "Platt (C 1e6) on 65% of them, a \(c.settings.folds)-fold cross-fitted gate (Brier Δ ≤ \(c.settings.maxBrierDelta), log loss Δ ≤ \(c.settings.maxLogLossDelta))"),
                        StageDecision(.evaluate, runs: true, "the threshold with real FPR ≤ \(c.settings.maxRealFPR) on the other 35%, band \(c.settings.band)"),
                        StageDecision(.write, runs: true, "calibration/warp_sensor_calibration.json, bound to the sensor model's SHA-256"),
                    ]
                } catch { p.refusal = "\(error)" }
                plans.append(p)

            case .fusion(let f):
                var p = ModelPlan(model: model.name, stages: [], refusal: storeMissing)
                let usable = storeRows.filter { !$0.row.golden && !$0.row.nsfw }
                var models: [String: Int] = [:]
                for r in usable { models[r.row.warpModel ?? "unknown", default: 0] += 1 }
                if models.count > 1 && !f.settings.allowMixedWarp {
                    p.refusal = "the store's warp column comes from \(models.count) warp models \(models); allow mixed warp rows to train anyway"
                }
                let newGen = usable.filter { r in r.row.isGenerated && f.settings.newGeneratorShards.contains { r.shard.hasPrefix($0) } }.count
                let mode: String
                switch f.settings.mode {
                case .warmStart(let add, let eta): mode = "warm start: +\(add) trees at η \(eta) onto the parent's fusion head \(parentBundle.sha256(.fusionHead)?.prefix(12) ?? "?")"
                case .scratch(let trees, let eta): mode = "from scratch: \(trees) trees at η \(eta)"
                }
                p.stages = [
                    StageDecision(.data, runs: true, "\(usable.count) store rows that are not golden or NSFW (those carrying dino_fusion), \(newGen) of them new-generator rows"),
                    StageDecision(.fit, runs: true, mode + ", depth \(f.settings.maxDepth), subsample \(f.settings.subsample), colsample \(f.settings.colsample)"),
                    StageDecision(.evaluate, runs: true, "recall on the \(Int(f.settings.holdoutFraction * 100))% of new-generator rows held out, and agreement with the parent"),
                    StageDecision(.write, runs: true, "fusion/fusion_head.xgb.json"),
                ]
                if warp != nil { p.notes.append("the store's warp column was computed by the warp models it records, not by the warp model this recipe trains") }
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

            case .combiner:
                var p = ModelPlan(model: model.name, stages: [], refusal: storeMissing)
                let base = trainsFusion ? "the fusion head this recipe trains" : "the parent's fusion head"
                // An art-pair head joins only when the recipe trains one or the parent carries one; the shipped bundle does not.
                let pairHere = trainedHeads.contains(.artPair) || parentBundle.url(.head, head: .artPair) != nil
                let heads = ([HeadKind.art, .blur, .human] + (pairHere ? [.artPair] : [])).map { trainedHeads.contains($0) ? "\($0.rawValue) (trained)" : "\($0.rawValue) (parent)" }.joined(separator: ", ")
                p.stages = [
                    StageDecision(.data, runs: true, "capture-absent store rows (not golden or NSFW): base from \(base); heads \(heads); noiseprint from the store"),
                    StageDecision(.fit, runs: true, "non-negative logistic, reals ×3, the rescue column zeroed (combiner v3)"),
                    StageDecision(.evaluate, runs: true, "the rescue sweep against \(CombinerProbe.userReals.count) protect-real probes; test AUC beside the base"),
                    StageDecision(.write, runs: true, "combiner/stack_combiner_v2.json"),
                ]
                plans.append(p)

            case .noiseprint(let n):
                var p = ModelPlan(model: model.name, stages: [], refusal: nil)
                let s = n.settings
                do {
                    let split = try s.split()
                    let families = s.sources.negatives.map { f in "\(f.name) \(split.counts[f.name]?[1] ?? 0)+\(split.counts[f.name]?[2] ?? 0)" }.joined(separator: ", ")
                    let empty = s.sources.negatives.filter { (split.counts[$0.name]?[0] ?? 0) == 0 }.map(\.name)
                    if empty.count == s.sources.negatives.count { p.refusal = "no negative family has images" }
                    let cache = NoiseprintTrainer.cacheDirectory(area).appendingPathComponent("patches_\(try NoiseprintTrainer.cacheKey(split, s)).safetensors")
                    let cached = s.cachePatches && FileManager.default.fileExists(atPath: cache.path)
                    p.stages = [
                        StageDecision(.data, runs: true, "camera \(split.cameraTrain.count)+\(split.cameraTest.count) (train+test) from \(s.sources.camera); negatives \(families)"),
                        StageDecision(.patches, runs: !cached, cached ? "the patches are cached at \(cache.path)"
                                      : "cut \(s.patches.cameraPatches) patches per camera image and \(s.patches.negativePatches) per negative, at \(s.patches.levels.map(\.rawValue).joined(separator: "/"))"),
                        StageDecision(.fit, runs: true, "\(s.epochs) epochs of Adam \(s.learningRate) (bias-corrected), batch \(s.batch), BCE, the Bayar projection after every step (GPU)"),
                        StageDecision(.evaluate, runs: true, "camera against each family at \(s.testLevels.map(\.rawValue).joined(separator: ", ")) on the held-out images, the anchor, beside the parent's net, judged by the adoption rules"),
                        StageDecision(.write, runs: true, "noiseprint/noiseprint_v1.safetensors (BatchNorms folded); the candidate's noiseprint weight entry re-pinned to it"),
                    ]
                    if !empty.isEmpty { p.notes.append("families with no images, skipped: \(empty.joined(separator: ", "))") }
                    p.notes.append("the shot_render and cgi families have no surviving images; ai_art reads Midjourney v6; ai_video and photoreal are added")
                    if !split.excluded.isEmpty { p.notes.append("excluded from every folder: \(split.excluded.joined(separator: ", "))") }
                    p.notes.append("the noiseprint is frozen in the flywheel: this net is for measurement; run it with --weights-dir <candidate>/noiseprint")
                } catch { p.refusal = "\(error)" }
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
        let parentBundle = try ModelBundle.load(parent)
        var candidate = try CandidateBundle.create(id: recipe.id, in: area, from: parentBundle, replacing: replace)
        try candidate.write(recipe, as: "recipe.json")
        log = try JSONLWriter(url: candidate.root.appendingPathComponent("runs.jsonl"), truncate: true)
        defer { log = nil }
        emit(.note("training \(recipe.id) into \(candidate.root.path)"))
        var metrics: [String: String] = [:]
        let ordered = recipe.ordered
        let warp = ordered.compactMap { if case .warpTile(let w) = $0 { return w } else { return nil } }.first

        for model in ordered {
            switch model {
            case .warpTile(let w):
                metrics[model.name] = try trainWarp(w, into: &candidate, parentBundle: parentBundle)
                if !ordered.contains(where: { if case .calibration = $0 { return true } else { return false } }),
                   let old = candidate.manifest.artifact(.sensorCalibration) {
                    candidate.dropArtifact(old)
                    try candidate.save()
                    emit(.note("calibration: dropped the parent's contract (bound to the old warp bytes); the sensor lane falls back to identity"))
                }
            case .calibration(let c):
                guard let dataset = c.dataset ?? warp?.dataset else { throw VeilGardeFailure.internalError("calibration without a dataset passed the plan") }
                metrics[model.name] = try trainCalibration(c, dataset: dataset, sample: warp, into: &candidate)
            case .fusion(let f):
                metrics[model.name] = try trainFusion(f, into: &candidate)
            case .head(let h):
                metrics[model.name] = try trainHead(h, into: &candidate)
            case .combiner(let c):
                metrics[model.name] = try trainCombiner(c, into: &candidate)
            case .noiseprint(let n):
                metrics[model.name] = try trainNoiseprint(n, into: &candidate)
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

    // MARK: Warp

    struct WarpMetrics: Codable {
        var recipe: WarpTileModel
        var trainImages: Int
        var trainTiles: Int
        var trees: Int
        var candidate: WarpEvaluation
        var parent: WarpEvaluation
        var parentNote: String
        var seconds: Double
        var sha256: String
    }

    private func trainWarp(_ w: WarpTileModel, into candidate: inout CandidateBundle, parentBundle: ModelBundle) throws -> String {
        let started = Date()
        let name = "warp-tile"
        let manifest = try self.manifest(for: w.dataset, samplePerLabel: w.samplePerLabel, seed: w.sampleSeed)
        let cache = tileCache(for: w.dataset)
        emit(.stage(model: name, .tiles))
        let cut = try TileExtractor.extract(manifest, into: cache, note: { self.emit(.note($0)) })
        if cut.images > 0 || !cut.failed.isEmpty {
            emit(.note("tiles: \(cut.images) images cut (\(cut.tiles) tiles), \(cut.skippedCached) cached, \(cut.failed.count) skipped"))
        }
        emit(.stage(model: name, .data))
        let stems = Set(manifest.records.map(\.stem))
        let shards = try cache.load()
        emit(.stage(model: name, .fit))
        let result = WarpTrainer.train(shards: shards, params: w.params, include: { stems.contains($0.stem) }, note: { self.emit(.note($0)) })
        emit(.stage(model: name, .evaluate))
        let parentModel = try GBDTModel.load(parentBundle.root.appendingPathComponent(parentBundle.manifest.artifact(.warpTile)!.file))
        let parentEval = WarpTrainer.evaluate(parentModel, validation: TileSet.gather(shards, partitions: [.val], include: { stems.contains($0.stem) }),
                                              test: TileSet.gather(shards, partitions: [.test], include: { stems.contains($0.stem) }))
        emit(.stage(model: name, .write))
        let json = result.model.encodeXGBoostJSON()
        let artifact = try candidate.put(json, as: "warp/warp_tile32.xgb.json", role: .warpTile)
        try candidate.put(json, as: "warp/warp_majority_tile32.xgb.json", role: .warpMajoritySensor)
        let metrics = WarpMetrics(recipe: w, trainImages: result.trainImages, trainTiles: result.trainTiles, trees: result.model.trees.count,
                                  candidate: result.evaluation, parent: parentEval,
                                  parentNote: "the parent's warp model scored on the same partitions; when the dataset is the parent's training corpus (final_mixed for optimal_8) these numbers are train-contaminated",
                                  seconds: Date().timeIntervalSince(started), sha256: artifact.sha256)
        return try record(metrics, model: name, as: "warp/metrics.json", in: candidate)
    }

    // MARK: Calibration

    struct CalibrationMetrics: Codable {
        var settings: CalibrationSettings
        var sensorModelSHA256: String
        var validationImages: Int
        var report: CalibrationReport
    }

    private func trainCalibration(_ c: SensorCalibration, dataset: URL, sample: WarpTileModel?, into candidate: inout CandidateBundle) throws -> String {
        let name = "sensor-calibration"
        let manifest = try self.manifest(for: dataset, samplePerLabel: sample?.samplePerLabel, seed: sample?.sampleSeed ?? 0)
        let cache = tileCache(for: dataset)
        emit(.stage(model: name, .tiles))
        _ = try TileExtractor.extract(manifest, into: cache, note: { self.emit(.note($0)) })
        emit(.stage(model: name, .data))
        guard let sensor = candidate.manifest.artifact(.warpMajoritySensor) else { throw VeilGardeFailure.missing("the candidate has no sensor model to calibrate") }
        let model = try GBDTModel.load(candidate.root.appendingPathComponent(sensor.file))
        let stems = Set(manifest.records.map(\.stem))
        let validation = TileSet.gather(try cache.load(), partitions: [.val], include: { stems.contains($0.stem) })
        let scores = WarpTrainer.imageScores(model, validation)
        let samples = zip(validation.images, scores.majority).map { CalibrationTrainer.Sample(key: $0.0.stem, label: $0.0.label, fraction: Double($0.1)) }
        emit(.note("calibration: \(samples.count) validation images under the sensor model \(sensor.sha256.prefix(12))"))
        emit(.stage(model: name, .fit))
        let variant = try SensorCalibrationContract.variant(featureCount: model.featureCount)
        let (file, report) = try CalibrationTrainer.fit(samples, settings: c.settings, sensorModelSHA256: sensor.sha256, sensorVariant: variant)
        emit(.stage(model: name, .evaluate))
        emit(.note(String(format: "calibration: %@, threshold %.4f (validation recall %.3f at real FPR ≤ %.2f)", report.calibration.rawValue,
                          report.operating.threshold, report.operating.generatedRecall, c.settings.maxRealFPR)))
        emit(.stage(model: name, .write))
        // The fitted contract, said as the two cuts on the vote where it changes its call.
        let fitted = try SensorCalibrationContract.decode(try JSONCoding.prettyEncoder().encode(file), expectedModelSHA256: sensor.sha256,
                                                          expectedSensorVariant: variant)
        guard let cuts = SensorCalibrationFile.twoCuts(from: fitted) else { throw VeilGardeFailure.data("the fitted calibration is two cuts already") }
        emit(.note(String(format: "calibration: real at or under %.4f of the tiles, generated at or over %.4f", cuts.cuts!.realAtOrBelow, cuts.cuts!.generatedAtOrAbove)))
        let data = try JSONCoding.prettyEncoder().encode(cuts)
        _ = try SensorCalibrationContract.decode(data, expectedModelSHA256: sensor.sha256, expectedSensorVariant: variant)
        try candidate.put(data, as: "calibration/warp_sensor_calibration.json", role: .sensorCalibration)
        return try record(CalibrationMetrics(settings: c.settings, sensorModelSHA256: sensor.sha256, validationImages: samples.count, report: report),
                          model: name, as: "calibration/metrics.json", in: candidate)
    }

    // MARK: Fusion

    struct FusionMetrics: Codable {
        var settings: FusionSettings
        var parentSHA256: String?
        var report: FusionReport
    }

    private func trainFusion(_ f: FusionHead, into candidate: inout CandidateBundle) throws -> String {
        let name = "fusion-head"
        emit(.stage(model: name, .data))
        let dataset = try FusionDataset.assemble(FeatureStore(directory: store), settings: f.settings)
        let parentArtifact = candidate.manifest.artifact(.fusionHead)
        let parentModel = try parentArtifact.map { try GBDTModel.load(candidate.root.appendingPathComponent($0.file)) }
        emit(.stage(model: name, .fit))
        let (model, report) = try FusionTrainer.train(dataset, settings: f.settings, parent: parentModel, note: { self.emit(.note($0)) })
        emit(.stage(model: name, .evaluate))
        emit(.note("fusion: held-out new-generator recall " + [report.heldOutRecallParent, report.heldOutRecallCandidate]
            .map { $0.map { String(format: "%.3f", $0) } ?? "n/a" }.joined(separator: " (parent) → ") + " (candidate)"
            + (report.agreementWithParent.map { String(format: ", agreement %.4f", $0) } ?? "")))
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
        let samples = CombinerSample.captureAbsent(selection, base: base, heads: heads, pair: pair)
        emit(.stage(model: name, .fit))
        let (file, report) = try CombinerTrainer.train(samples, settings: c.settings, note: { self.emit(.note($0)) })
        emit(.stage(model: name, .evaluate))
        emit(.note(String(format: "combiner: w_base %.3f, w_gen [%@], w_rescue %.1f, w_np %.2f", file.wBase,
                          file.wGen.map { String(format: "%.3f", $0) }.joined(separator: ", "), file.wRescue, file.wNp)))
        emit(.stage(model: name, .write))
        try candidate.put(try JSONCoding.prettyEncoder().encode(file), as: "combiner/stack_combiner_v2.json", role: .combiner)
        return try record(report, model: name, as: "combiner/metrics.json", in: candidate)
    }

    // MARK: Noiseprint

    private func trainNoiseprint(_ n: NoiseprintModel, into candidate: inout CandidateBundle) throws -> String {
        let name = "noiseprint"
        emit(.stage(model: name, .data))
        let parentNet = WeightLocator.shared.url(.noiseprint)
        if parentNet == nil { emit(.note("noiseprint: no parent net found by the weight search; the test runs on the candidate alone")) }
        let (file, report) = try NoiseprintTrainer.run(settings: n.settings, cacheDirectory: NoiseprintTrainer.cacheDirectory(area),
                                                       parent: parentNet, note: { self.emit(.note($0)) })
        emit(.stage(model: name, .write))
        try candidate.putWeight(file, as: "noiseprint/\(WeightFile.noiseprint.rawValue)", role: .noiseprint)
        try candidate.write(n, as: "noiseprint/recipe.json")
        return try record(report, model: name, as: "noiseprint/metrics.json", in: candidate)
    }
}
