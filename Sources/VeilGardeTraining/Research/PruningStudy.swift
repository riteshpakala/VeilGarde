//
//  PruningStudy.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What the shipped system could lose without losing its calls, measured on held-out data:
//        the warp tile model (its trees, its depth, its feature groups and single features, the
//        weight map against simpler image scores, the Platt layer against a cut on the raw tile
//        vote), the fusion head (its trees, its depth, its four inputs) and the stack (each
//        combiner term and head). Every row is a PairedComparison against the part it would
//        replace, judged by the rules fixed before the study ran (ledger decision-68).
//  PIN:  The warp studies refit the deployed shape (200 trees, depth 8, η 0.1, subsample and
//        colsample 0.8, seed 0) on final_mixed's train partition and score its test partition.
//        The shipped model is scored there too, but final_mixed is its own training corpus, so its
//        rows say how much it relies on a part, not how it generalizes. The fusion studies refit the
//        scratch recipe (depth 5, η 0.04, subsample and colsample 0.8, the fusion trainer's row
//        weights) on 80% of the store and score the other 20% (StableSplit "prune:v1"); the
//        shipped head's rows on that 20% are reliance, for the same reason. The stack studies pool
//        the store's capture-absent rows with the shipped combiner and heads, then again with one
//        term or head taken out. Nothing is written but the report.
//

import Foundation
import VeilGardeCore
import VeilGardeLens

public enum PruningPart: String, Codable, Sendable, CaseIterable {
    case warp, fusion, stack
}

public struct PruningSettings: Codable, Sendable, Equatable {
    public var resamples = 1000
    public var seed: UInt64 = 0
    /// The most held-out AUC a pruned part may cost.
    public var aucTolerance = 0.005
    /// The largest share of held-out calls a pruned part may move.
    public var callTolerance = 0.005
    /// The warp refits' shape (nil: the deployed shape, 200 trees at depth 8).
    public var warpParams: BoostParams? = nil
    public var warpStages = [10, 25, 50, 100, 150]
    public var warpDepths = [2, 4, 6]
    public var singleFeatures = true
    public var fusionTrees = 500
    public var fusionStages = [50, 100, 200, 300, 400]
    public var fusionDepths = [3, 7]
    public var fusionHoldout = 0.2
    public var shippedFusionStages = [100, 200, 400, 600, 900]
    /// Refits that change only the seed: how far a refit moves on its own (a control added after
    /// the first run; ledger decision-70).
    public var seedControls: [UInt64] = [1, 2]
    /// Warp groups dropped together, chosen after the first run from the groups each within the
    /// AUC tolerance alone.
    public var warpCombined: [[WarpFeatureGroup]] = [[.mirror, .seam, .cfa]]
    /// Fusion inputs (FeatureColumn names) dropped together, chosen the same way.
    public var fusionCombined: [[String]] = [["sharp", "warp"]]

    public init() {}

    /// The rules the report is judged by, as fixed before the study ran.
    public var rules: [String] {
        [
            "Every number is held out: warp on final_mixed's test partition, fusion on a 20% hash split of the store's rows; the stack's rows may have trained the shipped heads, so it counts changed calls.",
            String(format: "A part is within tolerance when taking it out costs at most %.3f AUC and moves at most %.1f%% of calls.", aucTolerance, callTolerance * 100),
            "Every difference carries a 95% bootstrap interval (\(resamples) Poisson resamples, seed \(seed)); an interval holding zero is no measurable difference.",
            "Nothing shipped changes: the findings are recommendations for the owner.",
            "Added after the first run, the rules unchanged: seed-only refits as a control for how far a refit moves on its own, and combined drops of parts each within the AUC tolerance alone.",
        ]
    }
}

/// The six families of the 19 warp features, by what each measures.
public enum WarpFeatureGroup: String, Codable, Sendable, CaseIterable {
    case residual, mirror, seam, demosaic, cfa, noise

    public var features: [String] {
        switch self {
        case .residual: return ["FR", "LV", "CV", "CM"]
        case .mirror: return ["CC", "CR"]
        case .seam: return ["SH", "SV", "SH_S", "SV_S"]
        case .demosaic: return ["xcorr_RG", "xcorr_BG", "xcorr_RB"]
        case .cfa: return ["cfa_G", "cfa_R", "cfa_B"]
        case .noise: return ["noise_ratio", "diag_axial", "nyq_R"]
        }
    }

    public var columns: [Int] { features.map { WarpFeatures.names.firstIndex(of: $0)! } }

    public var summary: String {
        switch self {
        case .residual: return "the warp residual's own statistics: fragility, local variance, direction coherence"
        case .mirror: return "the residual against its point-mirrored tile"
        case .seam: return "steps and spectra across the tile's lower and right seams"
        case .demosaic: return "cross-channel correlations of the high-passed planes"
        case .cfa: return "the colour filter array's period in each channel"
        case .noise: return "noise ratio, diagonal against axial energy, red Nyquist energy"
        }
    }
}

public struct PruningRow: Codable, Sendable, Equatable {
    public var name: String
    public var detail: String
    /// The consumer's score: the warp model's weighted score, the fusion base, the pooled stack.
    public var primary: PairedComparison
    /// The warp model's second consumer, the sensor lane's tile vote.
    public var secondary: PairedComparison?
    public var seconds: Double?
    /// within tolerance | costs AUC | moves calls
    public var verdict: String

    static func judge(_ comparisons: [PairedComparison], _ s: PruningSettings, calls: Bool = true) -> String {
        if comparisons.contains(where: { $0.delta < -s.aucTolerance }) { return "costs AUC" }
        if calls && comparisons.contains(where: { $0.changedShare > s.callTolerance }) { return "moves calls" }
        return "within tolerance"
    }
}

/// The Platt layer against the raw tile vote it calibrates.
public struct CalibrationEquivalence: Codable, Sendable, Equatable {
    public var coef: Double
    public var intercept: Double
    public var threshold: Double
    public var band: Double
    /// A tile vote at or under this reads real.
    public var rawReal: Double
    /// A tile vote at or over this reads generated; between the two it is inconclusive.
    public var rawGenerated: Double
    /// The vote at the threshold itself.
    public var rawThreshold: Double
    public var images: Int
    /// Images whose call is the same both ways.
    public var agreeing: Int
    public var calls: [String: Int]
}

public struct WarpPruning: Codable, Sendable, Equatable {
    public var trainImages: Int
    public var trainTiles: Int
    public var testImages: Int
    public var testTiles: Int
    /// The deployed shape refit on the train partition, on test.
    public var reference: PartitionMetrics
    public var referenceSeconds: Double
    /// The shipped model on the same test images (its own training corpus).
    public var shipped: PartitionMetrics
    public var trees: [PruningRow]
    public var depths: [PruningRow]
    /// The refit model with one group's columns shuffled across the test tiles.
    public var permuted: [PruningRow]
    /// Refit without one group.
    public var groupsDropped: [PruningRow]
    /// Refit without one feature.
    public var featuresDropped: [PruningRow]
    /// Refit without every feature whose single drop was within tolerance.
    public var droppedTogether: PruningRow?
    /// Refit without several groups at once (chosen after the first run).
    public var groupsTogether: [PruningRow]
    /// The deployed shape refit with another seed: the control.
    public var seeds: [PruningRow]
    /// Other image scores from the same tile probabilities, against the weighted score.
    public var scores: [PruningRow]
    public var shippedTrees: [PruningRow]
    public var shippedPermuted: [PruningRow]
    /// Each feature's share of the shipped model's total split gain.
    public var shippedGain: [String: Double]
    public var calibration: CalibrationEquivalence
}

public struct FusionPruning: Codable, Sendable, Equatable {
    public var rows: Int
    public var trainRows: Int
    public var testRows: Int
    public var warpModels: [String: Int]
    /// The scratch recipe on every input, on the test rows.
    public var referenceAUC: Double
    public var referenceSeconds: Double
    public var trees: [PruningRow]
    public var depths: [PruningRow]
    public var inputs: [PruningRow]
    /// Refit without several inputs at once (chosen after the first run).
    public var inputsTogether: [PruningRow]
    /// The scratch recipe refit with another seed: the control.
    public var seeds: [PruningRow]
    /// The shipped head on the same test rows (reliance: these rows may have trained it).
    public var shippedAUC: Double
    public var shippedTrees: [PruningRow]
    public var shippedPermuted: [PruningRow]
}

public struct StackPruning: Codable, Sendable, Equatable {
    public var rows: Int
    public var realRows: Int
    public var generatedRows: Int
    public var shippedAUC: Double
    public var shippedRealFPR: Double
    public var shippedGeneratedRecall: Double
    /// How often each term is live on these rows.
    public var active: [String: Int]
    public var variants: [PruningRow]
    /// Per variant, calls moved from real to generated and from generated to real.
    public var movedToGenerated: [String: Int]
    public var movedToReal: [String: Int]
    /// Per variant, of the calls it moves, how many the shipped stack had right (the rest the
    /// variant gets right): what taking the part out would break, against what it would fix.
    public var shippedRight: [String: Int]
}

public struct PruningReport: Codable, Sendable {
    public var date: Date
    public var settings: PruningSettings
    public var rules: [String]
    public var warp: WarpPruning?
    public var fusion: FusionPruning?
    public var stack: StackPruning?
    public var seconds: [String: Double]
}

public enum PruningStudy {
    public struct Inputs: Sendable {
        /// The tile cache the warp studies read (final_mixed's).
        public var tiles: URL
        /// The feature store the fusion and stack studies read.
        public var store: URL
        /// The shipped bundle.
        public var bundle: ModelBundle

        public init(tiles: URL, store: URL, bundle: ModelBundle) {
            self.tiles = tiles
            self.store = store
            self.bundle = bundle
        }

        func url(_ role: ArtifactRole, head: HeadKind? = nil) throws -> URL {
            guard let url = bundle.url(role, head: head) else { throw VeilGardeFailure.missing("the bundle has no \(role.rawValue)\(head.map { " \($0.rawValue)" } ?? "")") }
            return url
        }
    }

    public static func run(_ inputs: Inputs, settings: PruningSettings, parts: Set<PruningPart>, note: (String) -> Void = { _ in }) throws -> PruningReport {
        var report = PruningReport(date: Date(), settings: settings, rules: settings.rules, seconds: [:])
        for part in PruningPart.allCases where parts.contains(part) {
            let started = Date()
            switch part {
            case .warp: report.warp = try warp(inputs, settings, note: note)
            case .fusion: report.fusion = try fusion(inputs, settings, note: note)
            case .stack: report.stack = try stack(inputs, settings, note: note)
            }
            report.seconds[part.rawValue] = Date().timeIntervalSince(started)
        }
        return report
    }

    // MARK: Helpers

    static func padded(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

    static func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let started = Date()
        let value = try body()
        return (value, Date().timeIntervalSince(started))
    }

    /// The model's first `k` trees.
    static func truncated(_ model: GBDTModel, _ k: Int) -> GBDTModel {
        var m = model
        m.trees = Array(m.trees.prefix(k))
        return m
    }

    /// The dataset with only `columns`, in that order.
    static func keeping(_ data: BoostDataset, _ columns: [Int]) -> BoostDataset {
        let f = data.features
        var x = [Float]()
        x.reserveCapacity(data.count * columns.count)
        for i in 0..<data.count {
            let base = i * f
            for c in columns { x.append(data.x[base + c]) }
        }
        return BoostDataset(x: x, y: data.y, weight: data.weight, features: columns.count)
    }

    /// The dataset with `columns` shuffled across rows by one seeded permutation.
    static func permuting(_ data: BoostDataset, _ columns: [Int], seed: UInt64) -> BoostDataset {
        var rng = SplitMix64(seed: seed)
        let order = rng.permutation(data.count), f = data.features
        var x = data.x
        for (i, j) in order.enumerated() {
            for c in columns { x[i * f + c] = data.x[j * f + c] }
        }
        return BoostDataset(x: x, y: data.y, weight: data.weight, features: f)
    }

    static func predict(_ model: GBDTModel, _ data: BoostDataset) -> [Float] {
        var out = [Float](repeating: 0, count: data.count)
        let chunk = 2048
        out.withUnsafeMutableBufferPointer { p in
            DispatchQueue.concurrentPerform(iterations: (data.count + chunk - 1) / chunk) { c in
                for i in (c * chunk)..<min(data.count, (c + 1) * chunk) { p[i] = model.predict(data.row(i)) }
            }
        }
        return out
    }

    // MARK: The warp tile model

    static func warp(_ inputs: Inputs, _ s: PruningSettings, note: (String) -> Void) throws -> WarpPruning {
        let shards = try TileCache(directory: inputs.tiles).load()
        guard !shards.isEmpty else {
            throw VeilGardeFailure.missing("no tile cache at \(inputs.tiles.path)", hint: "veilgarde train warp cuts it, or point --tiles at one")
        }
        let train = TileSet.gather(shards, partitions: [.train]), test = TileSet.gather(shards, partitions: [.test])
        note("prune warp: \(train.images.count) train images (\(train.tileCount) tiles), \(test.images.count) test images (\(test.tileCount) tiles)")
        let rule = DecisionRule.warpWeighted
        func compare(_ ref: WarpTrainer.ImageScores, _ v: WarpTrainer.ImageScores) -> (PairedComparison, PairedComparison) {
            (PairedComparison.measure(reference: ref.weighted, variant: v.weighted, labels: ref.labels, resamples: s.resamples, seed: s.seed, call: rule.label),
             PairedComparison.measure(reference: ref.majority, variant: v.majority, labels: ref.labels, resamples: s.resamples, seed: s.seed, call: { _ in "" }))
        }
        func row(_ name: String, _ detail: String, _ ref: WarpTrainer.ImageScores, _ v: WarpTrainer.ImageScores, seconds: Double? = nil) -> PruningRow {
            let (w, m) = compare(ref, v)
            let r = PruningRow(name: name, detail: detail, primary: w, secondary: m, seconds: seconds, verdict: PruningRow.judge([w, m], s))
            note("prune warp: " + padded(name, 22) + String(format: " weighted %+.4f [%+.4f, %+.4f], vote %+.4f, calls moved %d — ", w.delta, w.low, w.high, m.delta, w.changedCalls) + r.verdict)
            return r
        }
        func subset(_ set: TileSet, _ columns: [Int]) -> TileSet {
            var t = set
            t.data = keeping(set.data, columns)
            return t
        }
        func refit(_ columns: [Int], params: BoostParams) -> (GBDTModel, Double) {
            timed { BoostTrainer.train(keeping(train.data, columns), params: params, featureNames: columns.map { WarpFeatures.names[$0] }).model }
        }
        let all = Array(0..<WarpFeatures.count)
        let params = s.warpParams ?? WarpShape.deployed.params
        let (refModel, refSeconds) = timed { BoostTrainer.train(train.data, params: params, featureNames: WarpFeatures.names).model }
        let ref = WarpTrainer.imageScores(refModel, test)
        note(String(format: "prune warp: the refit deployed shape in %.1fs", refSeconds))
        var seeds: [PruningRow] = []
        for seed in s.seedControls where seed != params.seed {
            var p = params
            p.seed = seed
            let (m, sec) = refit(all, params: p)
            seeds.append(row("seed \(seed)", "the deployed shape refit with seed \(seed) in place of \(params.seed): the control, how far a refit moves on its own",
                             ref, WarpTrainer.imageScores(m, test), seconds: sec))
        }

        var trees: [PruningRow] = []
        for k in s.warpStages where k < refModel.trees.count {
            trees.append(row("\(k) trees", "the refit model's first \(k) of \(refModel.trees.count) trees", ref, WarpTrainer.imageScores(truncated(refModel, k), test)))
        }
        var depths: [PruningRow] = []
        for d in s.warpDepths {
            var p = params
            p.maxDepth = d
            let (m, sec) = refit(all, params: p)
            depths.append(row("depth \(d)", "the deployed shape at depth \(d), \(p.trees) trees", ref, WarpTrainer.imageScores(m, test), seconds: sec))
        }
        var permuted: [PruningRow] = [], groupsDropped: [PruningRow] = []
        for (g, group) in WarpFeatureGroup.allCases.enumerated() {
            var shuffled = test
            shuffled.data = permuting(test.data, group.columns, seed: s.seed &+ UInt64(g))
            permuted.append(row(group.rawValue, "the refit model with \(group.features.joined(separator: ", ")) shuffled across test tiles", ref, WarpTrainer.imageScores(refModel, shuffled)))
            let keep = all.filter { !group.columns.contains($0) }
            let (m, sec) = refit(keep, params: params)
            groupsDropped.append(row("without \(group.rawValue)", "refit without \(group.features.joined(separator: ", ")): \(group.summary)", ref,
                                     WarpTrainer.imageScores(m, subset(test, keep)), seconds: sec))
        }
        var groupsTogether: [PruningRow] = []
        for combo in s.warpCombined where !combo.isEmpty {
            let gone = combo.flatMap(\.columns)
            let keep = all.filter { !gone.contains($0) }
            let (m, sec) = refit(keep, params: params)
            groupsTogether.append(row("without " + combo.map(\.rawValue).joined(separator: ", "),
                                      "refit without \(gone.count) features, \(combo.flatMap(\.features).joined(separator: ", ")); chosen after the first run, each group within the AUC tolerance alone",
                                      ref, WarpTrainer.imageScores(m, subset(test, keep)), seconds: sec))
        }
        var featuresDropped: [PruningRow] = []
        if s.singleFeatures {
            for f in all {
                let keep = all.filter { $0 != f }
                let (m, sec) = refit(keep, params: params)
                featuresDropped.append(row("without \(WarpFeatures.names[f])", "refit on the other 18 features", ref, WarpTrainer.imageScores(m, subset(test, keep)), seconds: sec))
            }
        }
        var droppedTogether: PruningRow?
        let droppable = featuresDropped.filter { $0.verdict == "within tolerance" }.map { String($0.name.dropFirst("without ".count)) }
        if droppable.count >= 2 {
            let gone = droppable.compactMap { WarpFeatures.names.firstIndex(of: $0) }
            let keep = all.filter { !gone.contains($0) }
            let (m, sec) = refit(keep, params: params)
            droppedTogether = row("without \(droppable.count) together", "refit without \(droppable.joined(separator: ", ")), each within tolerance alone",
                                  ref, WarpTrainer.imageScores(m, subset(test, keep)), seconds: sec)
        }

        // The weight map against simpler image scores from the same tile probabilities.
        var means: [Float] = [], medians: [Float] = []
        for image in test.images {
            let p = Array(ref.tileProbabilities[image.range]).sorted()
            means.append(p.reduce(0, +) / Float(max(1, p.count)))
            medians.append(p.isEmpty ? 0 : (p.count % 2 == 1 ? p[p.count / 2] : (p[p.count / 2 - 1] + p[p.count / 2]) / 2))
        }
        var scores: [PruningRow] = []
        for (name, detail, v) in [("plain mean", "the mean tile probability, no weight map or hotspot blend", means),
                                  ("median", "the median tile probability", medians),
                                  ("tile vote", "the share of tiles over 0.5 (the sensor lane's raw score)", ref.majority)] {
            let c = PairedComparison.measure(reference: ref.weighted, variant: v, labels: ref.labels, resamples: s.resamples, seed: s.seed, call: { _ in "" })
            scores.append(PruningRow(name: name, detail: detail + "; AUC only, the scores live on different scales", primary: c, secondary: nil, seconds: nil,
                                     verdict: PruningRow.judge([c], s, calls: false)))
            note("prune warp: " + padded(name, 22) + String(format: " against the weighted score %+.4f [%+.4f, %+.4f]", c.delta, c.low, c.high))
        }

        // The shipped model: reliance on its own corpus.
        let shipped = try GBDTModel.load(try inputs.url(.warpTile))
        let shippedScores = WarpTrainer.imageScores(shipped, test)
        var shippedTrees: [PruningRow] = []
        for k in s.warpStages where k < shipped.trees.count {
            shippedTrees.append(row("shipped, \(k) trees", "the shipped model's first \(k) of \(shipped.trees.count) trees", shippedScores, WarpTrainer.imageScores(truncated(shipped, k), test)))
        }
        var shippedPermuted: [PruningRow] = []
        for (g, group) in WarpFeatureGroup.allCases.enumerated() {
            var shuffled = test
            shuffled.data = permuting(test.data, group.columns, seed: s.seed &+ UInt64(g))
            shippedPermuted.append(row("shipped, \(group.rawValue)", "the shipped model with \(group.features.joined(separator: ", ")) shuffled", shippedScores,
                                       WarpTrainer.imageScores(shipped, shuffled)))
        }
        var gain = [Double](repeating: 0, count: shipped.featureCount)
        for tree in shipped.trees {
            for node in 0..<tree.nodeCount where tree.leftChildren[node] != -1 {
                let f = Int(tree.splitIndices[node])
                if f < gain.count { gain[f] += Double(tree.lossChanges[node]) }
            }
        }
        let total = gain.reduce(0, +)
        let shippedGain = Dictionary(uniqueKeysWithValues: gain.enumerated().map { (WarpFeatures.name(ofColumn: $0.offset), total > 0 ? $0.element / total : 0) })

        // The Platt layer against cuts on the raw vote.
        let calibrationURL = try inputs.url(.sensorCalibration)
        let contract = try SensorCalibrationContract.decode(Data(contentsOf: calibrationURL), expectedModelSHA256: inputs.bundle.sha256(.warpMajoritySensor) ?? "",
                                                            expectedSensorVariant: try SensorCalibrationContract.variant(featureCount: shipped.featureCount))
        let calibration = equivalence(contract, votes: shippedScores.majority)
        note(String(format: "prune warp: the calibrated sensor call equals a raw tile-vote cut on %d of %d test images (real ≤ %.4f, generated ≥ %.4f)",
                    calibration.agreeing, calibration.images, calibration.rawReal, calibration.rawGenerated))

        return WarpPruning(trainImages: train.images.count, trainTiles: train.tileCount, testImages: test.images.count, testTiles: test.tileCount,
                           reference: WarpTrainer.metrics(refModel, test), referenceSeconds: refSeconds, shipped: WarpTrainer.metrics(shipped, test),
                           trees: trees, depths: depths, permuted: permuted, groupsDropped: groupsDropped, featuresDropped: featuresDropped,
                           droppedTogether: droppedTogether, groupsTogether: groupsTogether, seeds: seeds, scores: scores,
                           shippedTrees: shippedTrees, shippedPermuted: shippedPermuted,
                           shippedGain: shippedGain, calibration: calibration)
    }

    /// The raw votes at which the contract's call turns, and how many of `votes` get the same call
    /// from those cuts as from the contract itself. A Platt contract's cuts are found over every
    /// float32 vote, so they are exact; two cuts are their own.
    public static func equivalence(_ contract: SensorCalibrationContract, votes: [Float]) -> CalibrationEquivalence {
        let a = contract.plattPayload?.coef ?? 1, b = contract.plattPayload?.intercept ?? 0
        let t = Double(contract.decisionThreshold), band = Double(contract.uncertainBand)
        let cuts = contract.equivalentCuts()
        let lo = cuts.realAtOrBelow, hi = cuts.generatedAtOrAbove
        // The vote at the threshold itself.
        let mid = contract.transform == .platt ? 1 / (1 + exp(-((log(t / (1 - t)) - b) / a))) : t
        var agreeing = 0
        var calls: [String: Int] = [:]
        for v in votes {
            let calibrated = contract.prediction(for: contract.calibratedProbability(v))
            let cut = Double(v) <= lo ? "real" : Double(v) >= hi ? "generated" : "inconclusive"
            if calibrated == cut { agreeing += 1 }
            calls[calibrated, default: 0] += 1
        }
        return CalibrationEquivalence(coef: a, intercept: b, threshold: t, band: band, rawReal: lo, rawGenerated: hi, rawThreshold: mid,
                                      images: votes.count, agreeing: agreeing, calls: calls)
    }

    // MARK: The fusion head

    /// The fusion vector's four inputs, as column ranges.
    static let fusionColumns: [(name: String, columns: [Int])] = {
        var start = 0
        var out: [(String, [Int])] = []
        for column in FeatureColumn.fusion {
            out.append((column.rawValue, Array(start..<(start + column.width))))
            start += column.width
        }
        return out
    }()

    static func fusion(_ inputs: Inputs, _ s: PruningSettings, note: (String) -> Void) throws -> FusionPruning {
        var settings = FusionSettings()
        settings.allowMixedWarp = true
        let dataset = try FusionDataset.assemble(FeatureStore(directory: inputs.store), settings: settings)
        let isTest = dataset.ids.map { StableSplit.isHoldout($0, salt: "prune:v1", fraction: s.fusionHoldout) }
        let train = dataset.subset { !isTest[$0] }, test = dataset.subset { isTest[$0] }
        note("prune fusion: \(dataset.data.count) store rows, \(train.count) to fit, \(test.count) held out; warp column from \(dataset.warpModels)")
        let rule = DecisionRule.fusion
        let params = BoostParams(trees: s.fusionTrees, maxDepth: 5, eta: 0.04, subsample: 0.8, colsampleByTree: 0.8, seed: s.seed)
        func compare(_ name: String, _ detail: String, _ ref: [Float], _ v: [Float], seconds: Double? = nil) -> PruningRow {
            let c = PairedComparison.measure(reference: ref, variant: v, labels: test.y, resamples: s.resamples, seed: s.seed, call: rule.label)
            let r = PruningRow(name: name, detail: detail, primary: c, secondary: nil, seconds: seconds, verdict: PruningRow.judge([c], s))
            note("prune fusion: " + padded(name, 24) + String(format: " AUC %+.4f [%+.4f, %+.4f], calls moved %d (%.2f%%) — ", c.delta, c.low, c.high, c.changedCalls, c.changedShare * 100) + r.verdict)
            return r
        }
        let everything = Array(0..<FusionVector.count)
        func fit(_ columns: [Int], _ p: BoostParams) -> ([Float], GBDTModel, Double) {
            let ((model, scores), sec) = timed { () -> (GBDTModel, [Float]) in
                let m = BoostTrainer.train(keeping(train, columns), params: p).model
                return (m, predict(m, keeping(test, columns)))
            }
            return (scores, model, sec)
        }
        let (ref, refModel, refSeconds) = fit(everything, params)
        let refAUC = RankedScores(ref, test.y).auc(nil) ?? .nan
        note(String(format: "prune fusion: the scratch recipe on all %d inputs, AUC %.4f, in %.0fs", everything.count, refAUC, refSeconds))
        var seeds: [PruningRow] = []
        for seed in s.seedControls where seed != params.seed {
            var p = params
            p.seed = seed
            let (v, _, sec) = fit(everything, p)
            seeds.append(compare("seed \(seed)", "the scratch recipe refit with seed \(seed): the control, how far a refit moves on its own", ref, v, seconds: sec))
        }

        var trees: [PruningRow] = []
        for k in s.fusionStages where k < refModel.trees.count {
            trees.append(compare("\(k) trees", "the refit head's first \(k) of \(refModel.trees.count) trees", ref, predict(truncated(refModel, k), test)))
        }
        var depths: [PruningRow] = []
        for d in s.fusionDepths {
            var p = params
            p.maxDepth = d
            let (v, _, sec) = fit(everything, p)
            depths.append(compare("depth \(d)", "the scratch recipe at depth \(d)", ref, v, seconds: sec))
        }
        let group = Dictionary(uniqueKeysWithValues: fusionColumns.map { ($0.name, $0.columns) })
        let warp = group["warp"]!, dino = group["dino_fusion"]!, cap = group["cap"]!, sharp = group["sharp"]!
        var rows: [PruningRow] = []
        for (name, detail, columns) in [("without warp", "every input but the warp lens's weighted score", dino + cap + sharp),
                                        ("without capture", "every input but the nine capture values", warp + dino + sharp),
                                        ("without sharpness", "every input but the three sharpness values", warp + dino + cap),
                                        ("DINOv2 alone", "the 384 DINOv2 values and nothing else", dino),
                                        ("without DINOv2", "warp, capture and sharpness: 13 values", warp + cap + sharp)] {
            let (v, _, sec) = fit(columns.sorted(), params)
            rows.append(compare(name, detail, ref, v, seconds: sec))
        }

        var together: [PruningRow] = []
        for drop in s.fusionCombined where !drop.isEmpty {
            let gone = drop.flatMap { group[$0] ?? [] }
            let keep = everything.filter { !gone.contains($0) }
            let (v, _, sec) = fit(keep, params)
            together.append(compare("without " + drop.joined(separator: " and "), "every input but \(drop.joined(separator: " and ")), \(gone.count) values; chosen after the first run, each within the AUC tolerance alone",
                                    ref, v, seconds: sec))
        }

        let shipped = try GBDTModel.load(try inputs.url(.fusionHead))
        let shippedScores = predict(shipped, test)
        let shippedAUC = RankedScores(shippedScores, test.y).auc(nil) ?? .nan
        var shippedTrees: [PruningRow] = []
        for k in s.shippedFusionStages where k < shipped.trees.count {
            shippedTrees.append(compare("shipped, \(k) trees", "the shipped head's first \(k) of \(shipped.trees.count) trees", shippedScores, predict(truncated(shipped, k), test)))
        }
        var shippedPermuted: [PruningRow] = []
        for (g, input) in fusionColumns.enumerated() {
            shippedPermuted.append(compare("shipped, \(input.name)", "the shipped head with its \(input.columns.count) \(input.name) values shuffled across the held-out rows",
                                           shippedScores, predict(shipped, permuting(test, input.columns, seed: s.seed &+ UInt64(g)))))
        }
        return FusionPruning(rows: dataset.data.count, trainRows: train.count, testRows: test.count, warpModels: dataset.warpModels,
                             referenceAUC: refAUC, referenceSeconds: refSeconds, trees: trees, depths: depths, inputs: rows,
                             inputsTogether: together, seeds: seeds, shippedAUC: shippedAUC, shippedTrees: shippedTrees, shippedPermuted: shippedPermuted)
    }

    // MARK: The stack

    static func stack(_ inputs: Inputs, _ s: PruningSettings, note: (String) -> Void) throws -> StackPruning {
        let base = try GBDTModel.load(try inputs.url(.fusionHead))
        let heads = try HeadKind.combinerOrder.map { try LinearHead.load(try inputs.url(.head, head: $0)) }
        let pair = try? LinearHead.load(try inputs.url(.head, head: .artPair))
        let combiner = try StackCombiner.load(try inputs.url(.combiner))
        let selection = try FeatureStore(directory: inputs.store).select(columns: Set(FeatureColumn.allCases)) { !$0.golden && !$0.nsfw }
        let samples = CombinerSample.captureAbsent(selection, base: base, heads: heads, pair: pair)
        let labels = samples.map { Float($0.label) }
        note("prune stack: \(samples.count) capture-absent store rows (\(labels.filter { $0 < 0.5 }.count) real)")

        func pooled(_ c: StackCombiner, without: Set<Int> = []) -> [Float] {
            samples.map { x in
                let h = x.heads.enumerated().map { without.contains($0.offset) ? Float(0) : Float($0.element) }
                return c.pool(base: Float(x.base), heads: h, pairAI: x.pair.map(Float.init), np: x.noiseprint.map(Float.init))
            }
        }
        let shipped = pooled(combiner)
        let call: (Float) -> String = { $0 > 0.5 ? "generated" : "real" }

        var active: [String: Int] = ["human gen push": 0, "rescue": 0, "noiseprint": 0, "art-pair lowers art": 0, "base under the gate": 0]
        for x in samples {
            let ls = combiner.headLogits(x.heads.map(Float.init), pairAI: x.pair.map(Float.init))
            let under = Float(x.base) < combiner.gateCeiling
            if under { active["base under the gate"]! += 1 }
            if combiner.wGen.count > 2 && combiner.wGen[2] > 0 && ls[2] > 0 { active["human gen push"]! += 1 }
            if under && (ls.max() ?? 0) < 0 && combiner.wRescue > 0 { active["rescue"]! += 1 }
            if under, let np = x.noiseprint, np > 0.5, (combiner.wNp ?? 0) > 0 { active["noiseprint"]! += 1 }
            if let p = x.pair, combiner.pairAdjudicates == true, combiner.lg(Float(p), combiner.capHead) < combiner.lg(Float(x.heads[0]), combiner.capHead) {
                active["art-pair lowers art"]! += 1
            }
        }

        var variants: [PruningRow] = [], toGenerated: [String: Int] = [:], toReal: [String: Int] = [:], right: [String: Int] = [:]
        func add(_ name: String, _ detail: String, _ v: [Float]) {
            let c = PairedComparison.measure(reference: shipped, variant: v, labels: labels, resamples: s.resamples, seed: s.seed, call: call)
            variants.append(PruningRow(name: name, detail: detail, primary: c, secondary: nil, seconds: nil, verdict: PruningRow.judge([c], s)))
            toGenerated[name] = zip(shipped, v).filter { call($0.0) == "real" && call($0.1) == "generated" }.count
            toReal[name] = zip(shipped, v).filter { call($0.0) == "generated" && call($0.1) == "real" }.count
            right[name] = labels.indices.filter { call(shipped[$0]) != call(v[$0]) && (call(shipped[$0]) == "generated") == (labels[$0] > 0.5) }.count
            note("prune stack: " + padded(name, 26) + String(format: " AUC %+.4f [%+.4f, %+.4f], calls moved %d (%.2f%%) — ", c.delta, c.low, c.high, c.changedCalls, c.changedShare * 100) + variants.last!.verdict)
        }
        var c = combiner
        add("the raw base", "the fusion head's P(AI) itself, no combiner", samples.map { Float($0.base) })
        c = combiner; c.wGen = c.wGen.map { _ in 0 }; c.wRescue = 0; c.wNp = 0
        add("the base, recalibrated", "w0 + w_base · lg(base): the combiner's base term alone", pooled(c))
        c = combiner; if c.wGen.count > 2 { c.wGen[2] = 0 }
        add("no human push", "the human head's generated push removed (its weight 0.197 to 0)", pooled(c))
        c = combiner; c.wRescue = 0
        add("no rescue", "the consensus-real rescue removed", pooled(c))
        c = combiner; c.wNp = 0
        add("no noiseprint", "noiseprint's camera evidence removed", pooled(c))
        c = combiner; c.pairAdjudicates = false
        add("no art-pair", "the art-pair adjudicator removed (the art logit stands alone)", pooled(c))
        add("no art head", "the art head removed (and with it the art-pair)", pooled(combiner, without: [0]))
        add("no blur head", "the blur head removed", pooled(combiner, without: [1]))
        add("no art or blur head", "both removed: the human head alone carries the rescue", pooled(combiner, without: [0, 1]))

        let real = labels.indices.filter { labels[$0] < 0.5 }, gen = labels.indices.filter { labels[$0] > 0.5 }
        return StackPruning(rows: samples.count, realRows: real.count, generatedRows: gen.count,
                            shippedAUC: RankedScores(shipped, labels).auc(nil) ?? .nan,
                            shippedRealFPR: Double(real.filter { shipped[$0] > 0.5 }.count) / Double(max(1, real.count)),
                            shippedGeneratedRecall: Double(gen.filter { shipped[$0] > 0.5 }.count) / Double(max(1, gen.count)),
                            active: active, variants: variants, movedToGenerated: toGenerated, movedToReal: toReal, shippedRight: right)
    }
}
