//
//  CoreStudy.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The majority route reduced to its core, measured. The warp tile model is refit on
//        pre-registered column masks, each 19 wide so it would deploy and calibrate as the
//        shipped model does; every arm's camera-sensor cuts are refit by the engine's own rule;
//        and each arm is scored on held-out images: its AUCs, its sensor calls by source pool
//        (the iPhone originals' real share is the camera-signature measure), and paired
//        comparisons against the full model and against the FR, LV, CV trio. A forward selection
//        grows the trio one feature at a time while a feature still moves the vote. The rules
//        that judge each row and name the golden combination were fixed before the study ran.
//  PIN:  The deployed shape (200 trees, depth 8, η 0.1, subsample and colsample 0.8, seed 0) under
//        BoostParams.allowedColumns, the column sample taken over the mask. Fit on final_mixed's
//        train partition; cuts from its validation partition by CalibrationTrainer.fit, said as
//        the two cuts that call every vote as the fitted contract does (TrainingEngine's
//        calibration step); scored on its test partition. With a left-out pool, the pool leaves
//        train and validation and is scored whole beside the test partition. Comparisons are
//        PairedComparison's (1,000 Poisson resamples, seed 0); the vote lane calls each side with
//        its own cuts, the weighted lane at the detector's 0.56 ± 0.04. Nothing is written but
//        the report.
//

import Foundation
import VeilGardeCore

public struct CoreSettings: Codable, Sendable, Equatable {
    public var resamples = 1000
    public var seed: UInt64 = 0
    /// R2: the golden arm's vote AUC is at least the full model's minus this.
    public var aucTolerance = 0.005
    /// R2: the camera pool's real-call share at least the full model's minus this, and the
    /// generated images called real at most the full model's share plus this.
    public var poolTolerance = 0.02
    public var seedControls: [UInt64] = [1, 2]
    /// The refits' shape (nil: the deployed shape, 200 trees at depth 8).
    public var warpParams: BoostParams? = nil
    public var calibration = CalibrationSettings()
    /// The registered arms to run (nil: every one); the reference, the seed controls and the trio always run.
    public var arms: [String]? = nil
    public var forwardSelection = true
    public var maxForwardSteps = 16
    /// A source pool taken out of train and validation and scored whole beside the test partition.
    public var leavePoolOut: String? = nil
    /// The pool whose real-call share is the camera-signature measure.
    public var cameraPool = "iphone"

    public init() {}

    /// The rules every report is judged by, as fixed before the study ran (2026-10-20).
    public var rules: [String] {
        [
            "R0. Every arm is the deployed shape (200 trees, depth 8, η 0.1, subsample 0.8, seed 0) refit on final_mixed's train partition under a column mask; colsample 0.8 is taken over the mask (the trio's trees each see 2 of its 3 columns), and every model stays 19 columns wide. Each arm's sensor cuts are refit on the validation partition by the engine's rule (Platt on the vote when its cross-fitted gate passes, else the identity; the threshold at real FPR ≤ 0.10, band 0.04; said as two cuts). Every number is held out: the test partition, and the whole left-out pool when one is named.",
            "Every difference carries a 95% bootstrap interval (\(resamples) Poisson resamples, seed \(seed)); the vote lane calls each side with its own cuts, the weighted lane at the detector's 0.56 ± 0.04.",
            "The seed floor is the largest |Δ vote AUC| between the full model refit with seed \(seedControls.map(String.init).joined(separator: " or ")) and with seed \(seed).",
            "R1. A feature moves the needle when the vote AUC it adds to the trio (FR, LV, CV) has a 95% interval that excludes zero and a gain above the seed floor. The weighted lane is reported, not judged.",
            "Forward selection starts from the trio, adds at each step the candidate with the largest vote-AUC gain over the current set, and stops when that gain's interval holds zero or the gain does not exceed the seed floor.",
            String(format: "R2. The golden combination is the smallest arm (fewest columns; ties to the forward-selection order, then the registration order) whose vote AUC is at least the full model's minus %.3f, whose %@ real-call share is at least the full model's minus %.2f, and whose share of generated images called real is at most the full model's plus %.2f. Across the stem-split and left-out-pool runs it is the smallest arm that qualifies in both; if none qualifies, the full model is named.", aucTolerance, cameraPool, poolTolerance, poolTolerance),
            "Limits stated before the run: one seed floor, measured at 19 columns, stands for every arm; nothing adjusts for the number of arms compared; a left-out pool's AUCs are over the test partition and the pool, not comparable to the stem-split run's; the test partition holds 74 \(cameraPool) images.",
            "Nothing shipped changes: the findings are recommendations for the owner.",
        ]
    }
}

public enum CoreArmKind: String, Codable, Sendable {
    case reference, seed, trio, single, group, control, forward
}

/// One refit: the columns its trees may split on and its seed.
public struct CoreArm: Codable, Sendable, Equatable {
    public var name: String
    public var detail: String
    /// nil: all 19.
    public var columns: [Int]?
    public var seed: UInt64
    public var kind: CoreArmKind

    public var allowed: [Int] { columns ?? Array(0..<WarpFeatures.count) }
    public var width: Int { allowed.count }
}

/// The camera-sensor cuts an arm's validation images gave it.
public struct CoreCalibration: Codable, Sendable, Equatable {
    /// The fitted contract before it is said as two cuts: platt or identity.
    public var transform: String
    public var plattQualifies: Bool
    public var coef: Double?
    public var intercept: Double?
    public var threshold: Double
    public var validationRecall: Double
    public var realAtOrBelow: Double
    public var generatedAtOrAbove: Double
    public var validationImages: Int

    public var cuts: SensorCuts { SensorCuts(realAtOrBelow: realAtOrBelow, generatedAtOrAbove: generatedAtOrAbove) }
}

/// The sensor calls on the scored images.
public struct CoreSensorPoint: Codable, Sendable, Equatable {
    public var realImages: Int
    public var generatedImages: Int
    public var realCalledReal: Double
    public var realInconclusive: Double
    public var realCalledGenerated: Double
    public var generatedCalledGenerated: Double
    public var generatedInconclusive: Double
    public var generatedCalledReal: Double
}

/// One source pool's sensor calls.
public struct CorePoolRow: Codable, Sendable, Equatable {
    public var pool: String
    public var label: Int
    public var images: Int
    public var real: Double
    public var inconclusive: Double
    public var generated: Double
    /// The share called the pool's own label, with its 95% Wilson interval.
    public var right: Double
    public var rightLow: Double
    public var rightHigh: Double
}

/// One arm against another, on both lanes.
public struct CorePair: Codable, Sendable, Equatable {
    public var weighted: PairedComparison
    public var vote: PairedComparison
}

public struct CoreArmRow: Codable, Sendable, Equatable {
    public var arm: CoreArm
    public var features: [String]
    /// The model's width: 19 for every arm.
    public var width: Int
    /// The columns its trees actually split on.
    public var splitColumns: [Int]
    public var modelSHA256: String
    public var metrics: PartitionMetrics
    public var calibration: CoreCalibration
    public var sensor: CoreSensorPoint
    /// The camera pool's real-call share (nil when the scored images hold none).
    public var cameraRealShare: Double?
    public var againstAll19: CorePair
    public var againstTrio: CorePair
    public var pools: [CorePoolRow]
    /// The forward-selection step that chose this set (0 for the trio), when it lies on the path.
    public var forwardStep: Int?
    public var seconds: Double
    /// R1, against the trio: moves the needle | within the seed floor | no measurable gain | costs vote AUC | reference | control
    public var needle: String
    /// Against the full model's vote AUC: within tolerance | better | costs AUC | reference | control
    public var distance: String
    /// R2's three clauses.
    public var qualifies: Bool
}

public struct CoreForwardCandidate: Codable, Sendable, Equatable {
    public var feature: String
    public var columns: [Int]
    /// Against the current set.
    public var vote: PairedComparison
    public var weighted: PairedComparison
}

public struct CoreForwardStep: Codable, Sendable, Equatable {
    public var step: Int
    public var base: [String]
    public var candidates: [CoreForwardCandidate]
    public var best: String
    public var gain: Double
    public var low: Double
    public var high: Double
    public var picked: String?
    public var stopped: String?
}

public struct CoreGolden: Codable, Sendable, Equatable {
    public var name: String
    public var columns: [Int]
    public var features: [String]
    public var qualifies: Bool
    public var reason: String
    /// Every arm that met R2, in R2's order.
    public var qualifying: [String]
}

public struct CorePartitions: Codable, Sendable, Equatable {
    public var trainImages: Int
    public var trainTiles: Int
    public var validationImages: Int
    public var validationTiles: Int
    public var scoredImages: Int
    public var scoredTiles: Int
    public var leftOutPool: String?
    public var leftOutImages: Int
    /// Scored images by "pool/label".
    public var scoredPools: [String: Int]
}

/// The shipped model on the same scored images, with its own cuts (reliance: final_mixed is its own corpus).
public struct CoreShipped: Codable, Sendable, Equatable {
    public var sha256: String
    public var metrics: PartitionMetrics
    public var cuts: SensorCuts
    public var sensor: CoreSensorPoint
    public var cameraRealShare: Double?
    public var pools: [CorePoolRow]
    public var note: String
}

public struct CoreReport: Codable, Sendable {
    public var date: Date
    public var settings: CoreSettings
    public var rules: [String]
    public var partitions: CorePartitions
    public var seedFloor: Double
    /// The reference first, then every arm in registration order, then the forward path's new sets.
    public var rows: [CoreArmRow]
    public var forward: [CoreForwardStep]
    public var golden: CoreGolden
    public var shipped: CoreShipped?
    public var seconds: Double
}

public enum CoreStudy {
    public struct Inputs: Sendable {
        /// The tile cache (final_mixed's).
        public var tiles: URL
        /// The shipped bundle, for its model's own numbers on the same images (optional).
        public var bundle: ModelBundle?

        public init(tiles: URL, bundle: ModelBundle? = nil) {
            self.tiles = tiles
            self.bundle = bundle
        }
    }

    public static let trio = [0, 1, 2]
    public static let rawNine = Array(10..<WarpFeatures.count)

    /// Every pre-registered arm, in registration order.
    public static func registeredArms(_ s: CoreSettings) -> [CoreArm] {
        let names = WarpFeatures.names
        var arms = [CoreArm(name: "all19", detail: "every feature: the reference", columns: nil, seed: s.seed, kind: .reference)]
        for seed in s.seedControls where seed != s.seed {
            arms.append(CoreArm(name: "seed \(seed)", detail: "every feature refit with seed \(seed): how far a refit moves on its own", columns: nil, seed: seed, kind: .seed))
        }
        arms.append(CoreArm(name: "trio", detail: "FR, LV, CV: the warp residual's fragility, local variance and direction coherence", columns: trio, seed: s.seed, kind: .trio))
        for c in 3..<WarpFeatures.count {
            arms.append(CoreArm(name: "trio+\(names[c])", detail: "the trio and \(names[c])", columns: trio + [c], seed: s.seed, kind: .single))
        }
        for group in [WarpFeatureGroup.demosaic, .cfa, .noise, .mirror, .seam] {
            arms.append(CoreArm(name: "trio+\(group.rawValue)", detail: "the trio and \(group.features.joined(separator: ", ")): \(group.summary)",
                                columns: (trio + group.columns).sorted(), seed: s.seed, kind: .group))
        }
        arms.append(CoreArm(name: "trio+raw9", detail: "the trio and the nine raw-tile features", columns: trio + rawNine, seed: s.seed, kind: .group))
        arms.append(CoreArm(name: "residual10", detail: "the ten warp-residual features: the round trip alone", columns: Array(0..<10), seed: s.seed, kind: .control))
        arms.append(CoreArm(name: "raw9", detail: "the nine raw-tile features: no warp at all", columns: rawNine, seed: s.seed, kind: .control))
        return arms
    }

    /// The arms a run measures: the settings' names (validated) and the three that always run.
    public static func chosenArms(_ s: CoreSettings) throws -> [CoreArm] {
        let all = registeredArms(s)
        guard let wanted = s.arms else { return all }
        if let unknown = wanted.first(where: { name in !all.contains { $0.name == name } }) {
            throw VeilGardeFailure.usage("no registered arm is named \(unknown)", hint: "the arms are \(all.map(\.name).joined(separator: ", "))")
        }
        return all.filter { [.reference, .seed, .trio].contains($0.kind) || wanted.contains($0.name) }
    }

    // MARK: Data and fits

    struct Sets {
        var train: TileSet
        var validation: TileSet
        var scored: TileSet
        var labels: [Float]
        var leftOut: Int
    }

    static func sets(_ shards: [TileShard], leftOut: String?) -> Sets {
        let keep: (TileImage) -> Bool = { image in leftOut.map { image.pool != $0 } ?? true }
        let train = TileSet.gather(shards, partitions: [.train], include: keep)
        let validation = TileSet.gather(shards, partitions: [.val], include: keep)
        let scored = TileSet.gather(shards, partitions: Set(Partition.allCases), include: { image in
            image.split == .test || (leftOut.map { image.pool == $0 } ?? false)
        })
        let leftOutCount = leftOut.map { pool in shards.reduce(0) { $0 + $1.images.filter { $0.pool == pool }.count } } ?? 0
        return Sets(train: train, validation: validation, scored: scored, labels: scored.images.map { Float($0.label) }, leftOut: leftOutCount)
    }

    struct Fit {
        var sha256: String
        var width: Int
        var splitColumns: [Int]
        var metrics: PartitionMetrics
        var weighted: [Float]
        var majority: [Float]
        var calibration: CoreCalibration
        var seconds: Double

        var cuts: SensorCuts { calibration.cuts }
    }

    /// The deployed shape (or `params`) refit on `train` under `columns`, 19 wide.
    static func model(_ columns: [Int]?, seed: UInt64, train: TileSet, params: BoostParams) -> GBDTModel {
        var p = params
        p.allowedColumns = columns
        p.seed = seed
        return BoostTrainer.train(train.data, params: p, featureNames: WarpFeatures.names).model
    }

    /// The deployed shape refit under `columns`, scored, and calibrated.
    static func fit(_ columns: [Int]?, seed: UInt64, sets: Sets, params: BoostParams, calibration: CalibrationSettings) throws -> Fit {
        let started = Date()
        let model = Self.model(columns, seed: seed, train: sets.train, params: params)
        let sha = ContentHash.sha256Hex(model.encodeXGBoostJSON())
        let scored = WarpTrainer.imageScores(model, sets.scored)
        let validation = WarpTrainer.imageScores(model, sets.validation)
        let rule = WarpTrainer.decision
        let metrics = PartitionMetrics(images: sets.scored.images.count, tiles: sets.scored.tileCount,
                                       tileAUC: Metrics.auc(scored.tileProbabilities, sets.scored.data.y),
                                       imageWeightedAUC: Metrics.auc(scored.weighted, scored.labels),
                                       imageMajorityAUC: Metrics.auc(scored.majority, scored.labels),
                                       weighted: Metrics.operatingPoint(scored.weighted, scored.labels, threshold: Double(rule.threshold), band: Double(rule.band)))
        var used = Set<Int>()
        for tree in model.trees {
            for node in 0..<tree.nodeCount where tree.leftChildren[node] != -1 { used.insert(Int(tree.splitIndices[node])) }
        }
        let cal = try cuts(validation: sets.validation, majority: validation.majority, sha256: sha, featureCount: model.featureCount, settings: calibration)
        return Fit(sha256: sha, width: model.featureCount, splitColumns: used.sorted(), metrics: metrics, weighted: scored.weighted,
                   majority: scored.majority, calibration: cal, seconds: Date().timeIntervalSince(started))
    }

    /// The engine's calibration step on these validation votes, said as two cuts.
    static func cuts(validation: TileSet, majority: [Float], sha256: String, featureCount: Int, settings: CalibrationSettings) throws -> CoreCalibration {
        let samples = zip(validation.images, majority).map { CalibrationTrainer.Sample(key: $0.0.stem, label: $0.0.label, fraction: Double($0.1)) }
        let variant = try SensorCalibrationContract.variant(featureCount: featureCount)
        let (file, report) = try CalibrationTrainer.fit(samples, settings: settings, sensorModelSHA256: sha256, sensorVariant: variant)
        let contract = try SensorCalibrationContract.decode(try JSONCoding.prettyEncoder().encode(file), expectedModelSHA256: sha256, expectedSensorVariant: variant)
        let c = contract.equivalentCuts()
        return CoreCalibration(transform: report.calibration.rawValue, plattQualifies: report.plattQualifies,
                               coef: report.plattQualifies ? report.platt.coef : nil, intercept: report.plattQualifies ? report.platt.intercept : nil,
                               threshold: report.operating.threshold, validationRecall: report.operating.generatedRecall,
                               realAtOrBelow: c.realAtOrBelow, generatedAtOrAbove: c.generatedAtOrAbove, validationImages: samples.count)
    }

    // MARK: Measures

    static func sensor(_ votes: [Float], labels: [Float], cuts: SensorCuts) -> CoreSensorPoint {
        var r = [0, 0, 0], g = [0, 0, 0]          // real, inconclusive, generated
        for (v, y) in zip(votes, labels) {
            let k = ["real": 0, "inconclusive": 1, "generated": 2][cuts.call(v)]!
            if y > 0.5 { g[k] += 1 } else { r[k] += 1 }
        }
        let nr = r.reduce(0, +), ng = g.reduce(0, +)
        func share(_ k: Int, _ n: Int) -> Double { n > 0 ? Double(k) / Double(n) : .nan }
        return CoreSensorPoint(realImages: nr, generatedImages: ng, realCalledReal: share(r[0], nr), realInconclusive: share(r[1], nr),
                               realCalledGenerated: share(r[2], nr), generatedCalledGenerated: share(g[2], ng),
                               generatedInconclusive: share(g[1], ng), generatedCalledReal: share(g[0], ng))
    }

    /// The 95% Wilson interval of k successes in n.
    static func wilson(_ k: Int, _ n: Int) -> (low: Double, high: Double) {
        guard n > 0 else { return (.nan, .nan) }
        let z = 1.959963984540054, nn = Double(n), p = Double(k) / nn
        let denominator = 1 + z * z / nn
        let centre = (p + z * z / (2 * nn)) / denominator
        let half = z * (p * (1 - p) / nn + z * z / (4 * nn * nn)).squareRoot() / denominator
        return (max(0, centre - half), min(1, centre + half))
    }

    static func pools(_ votes: [Float], images: [TileImage], cuts: SensorCuts) -> [CorePoolRow] {
        var counts: [String: [Int]] = [:]          // "pool|label" → real, inconclusive, generated
        for (v, image) in zip(votes, images) {
            let key = "\(image.pool ?? "unknown")|\(image.label)"
            let k = ["real": 0, "inconclusive": 1, "generated": 2][cuts.call(v)]!
            counts[key, default: [0, 0, 0]][k] += 1
        }
        return counts.keys.sorted().map { key in
            let parts = key.split(separator: "|"), c = counts[key]!, n = c.reduce(0, +)
            let label = Int(parts[1])!, right = label == 1 ? c[2] : c[0]
            let w = wilson(right, n)
            return CorePoolRow(pool: String(parts[0]), label: label, images: n, real: Double(c[0]) / Double(n), inconclusive: Double(c[1]) / Double(n),
                               generated: Double(c[2]) / Double(n), right: Double(right) / Double(n), rightLow: w.low, rightHigh: w.high)
        }
    }

    static func cameraShare(_ pools: [CorePoolRow], _ s: CoreSettings) -> Double? {
        pools.first { $0.pool == s.cameraPool && $0.label == 0 }?.real
    }

    static func pair(_ reference: Fit, _ variant: Fit, labels: [Float], _ s: CoreSettings) -> CorePair {
        let rule = WarpTrainer.decision
        let refCuts = reference.cuts, varCuts = variant.cuts
        return CorePair(weighted: PairedComparison.measure(reference: reference.weighted, variant: variant.weighted, labels: labels,
                                                           resamples: s.resamples, seed: s.seed, call: rule.label),
                        vote: PairedComparison.measure(reference: reference.majority, variant: variant.majority, labels: labels, resamples: s.resamples,
                                                       seed: s.seed, referenceCall: refCuts.call, variantCall: varCuts.call))
    }

    /// R1 on a vote comparison against the trio.
    static func needle(_ c: PairedComparison, seedFloor: Double) -> String {
        if c.high < 0 { return "costs vote AUC" }
        if c.low <= 0 { return "no measurable gain" }
        return c.delta > seedFloor ? "moves the needle" : "within the seed floor"
    }

    /// The vote AUC against the full model's.
    static func distance(_ c: PairedComparison, _ s: CoreSettings) -> String {
        if c.delta < -s.aucTolerance { return "costs AUC" }
        return c.low > 0 ? "better" : "within tolerance"
    }

    // MARK: The golden rule

    /// What R2 reads off a row.
    struct GoldenInput: Equatable {
        var name: String
        var columns: [Int]
        var voteAUC: Double
        var cameraRealShare: Double?
        var generatedCalledReal: Double
        /// The forward-selection step that chose the set (Int.max off the path).
        var forwardStep: Int
        /// Registration order.
        var order: Int
    }

    static func qualifies(_ x: GoldenInput, reference r: GoldenInput, _ s: CoreSettings) -> Bool {
        guard x.voteAUC >= r.voteAUC - s.aucTolerance, x.generatedCalledReal <= r.generatedCalledReal + s.poolTolerance else { return false }
        switch (x.cameraRealShare, r.cameraRealShare) {
        case let (a?, b?): return a >= b - s.poolTolerance
        case (nil, nil): return true             // no camera pool scored: the clause cannot be measured
        default: return false
        }
    }

    static func golden(_ candidates: [GoldenInput], reference: GoldenInput, _ s: CoreSettings) -> CoreGolden {
        let ok = candidates.filter { qualifies($0, reference: reference, s) }
            .sorted { ($0.columns.count, $0.forwardStep, $0.order) < ($1.columns.count, $1.forwardStep, $1.order) }
        let names: ([Int]) -> [String] = { $0.map { WarpFeatures.names[$0] } }
        guard let best = ok.first else {
            return CoreGolden(name: reference.name, columns: reference.columns, features: names(reference.columns), qualifies: false,
                              reason: "no arm met R2, so the full model is named", qualifying: [])
        }
        var reason = String(format: "the smallest arm meeting R2: vote AUC %.4f against the full model's %.4f; generated called real %.3f against %.3f",
                            best.voteAUC, reference.voteAUC, best.generatedCalledReal, reference.generatedCalledReal)
        if let a = best.cameraRealShare, let b = reference.cameraRealShare {
            reason += String(format: "; %@ real share %.3f against %.3f", s.cameraPool, a, b)
        } else {
            reason += "; no \(s.cameraPool) image was scored, so that clause was not measured"
        }
        return CoreGolden(name: best.name, columns: best.columns, features: names(best.columns), qualifies: true, reason: reason, qualifying: ok.map(\.name))
    }

    static func goldenInput(_ row: CoreArmRow, order: Int) -> GoldenInput {
        GoldenInput(name: row.arm.name, columns: row.arm.allowed, voteAUC: row.metrics.imageMajorityAUC, cameraRealShare: row.cameraRealShare,
                    generatedCalledReal: row.sensor.generatedCalledReal, forwardStep: row.forwardStep ?? Int.max, order: order)
    }

    /// R2 across runs (the stem split and the left-out pool): the smallest arm that qualifies in every report.
    public static func golden(across reports: [CoreReport]) -> CoreGolden {
        guard let first = reports.first else {
            return CoreGolden(name: "all19", columns: Array(0..<WarpFeatures.count), features: WarpFeatures.names, qualifies: false, reason: "no report", qualifying: [])
        }
        let everywhere = first.rows.enumerated().filter { _, row in
            row.qualifies && reports.dropFirst().allSatisfy { r in r.rows.contains { $0.arm.name == row.arm.name && $0.qualifies } }
        }.sorted { a, b in
            (a.element.arm.width, a.element.forwardStep ?? Int.max, a.offset) < (b.element.arm.width, b.element.forwardStep ?? Int.max, b.offset)
        }
        guard let best = everywhere.first?.element else {
            return CoreGolden(name: "all19", columns: Array(0..<WarpFeatures.count), features: WarpFeatures.names, qualifies: false,
                              reason: "no arm met R2 in all \(reports.count) runs, so the full model is named", qualifying: [])
        }
        return CoreGolden(name: best.arm.name, columns: best.arm.allowed, features: best.features, qualifies: true,
                          reason: "the smallest arm meeting R2 in all \(reports.count) runs", qualifying: everywhere.map(\.element.arm.name))
    }

    // MARK: The run

    public static func run(_ inputs: Inputs, settings s: CoreSettings, note: (String) -> Void = { _ in }) throws -> CoreReport {
        let started = Date()
        let arms = try chosenArms(s)
        let data: Sets = try {
            let shards = try TileCache(directory: inputs.tiles).load()
            guard !shards.isEmpty else { throw VeilGardeFailure.missing("no tile cache at \(inputs.tiles.path)", hint: "veilgarde features tiles cuts it") }
            if let pool = s.leavePoolOut, !shards.contains(where: { $0.images.contains { $0.pool == pool } }) {
                throw VeilGardeFailure.usage("no image in the tile cache comes from the pool \(pool)")
            }
            return sets(shards, leftOut: s.leavePoolOut)
        }()
        var scoredPools: [String: Int] = [:]
        for image in data.scored.images { scoredPools["\(image.pool ?? "unknown")/\(image.label == 1 ? "generated" : "real")", default: 0] += 1 }
        let partitions = CorePartitions(trainImages: data.train.images.count, trainTiles: data.train.tileCount, validationImages: data.validation.images.count,
                                        validationTiles: data.validation.tileCount, scoredImages: data.scored.images.count, scoredTiles: data.scored.tileCount,
                                        leftOutPool: s.leavePoolOut, leftOutImages: data.leftOut, scoredPools: scoredPools)
        note("core: \(partitions.trainImages) train images (\(partitions.trainTiles) tiles), \(partitions.validationImages) validation, \(partitions.scoredImages) scored"
             + (s.leavePoolOut.map { ", the \($0) pool (\(data.leftOut) images) left out of train and validation" } ?? ""))
        let params = s.warpParams ?? WarpShape.deployed.params
        var cache: [String: Fit] = [:]
        func fitted(_ columns: [Int]?, _ seed: UInt64) throws -> Fit {
            let key = (columns?.map(String.init).joined(separator: ",") ?? "all") + "|\(seed)"
            if let hit = cache[key] { return hit }
            let f = try fit(columns, seed: seed, sets: data, params: params, calibration: s.calibration)
            cache[key] = f
            return f
        }

        // The reference, the seed floor, the trio.
        let all19 = try fitted(nil, s.seed)
        note(String(format: "core: all19 in %.1fs, vote AUC %.4f, weighted AUC %.4f, cuts %.4f / %.4f", all19.seconds, all19.metrics.imageMajorityAUC,
                    all19.metrics.imageWeightedAUC, all19.cuts.realAtOrBelow, all19.cuts.generatedAtOrAbove))
        var seedFloor = 0.0
        for arm in arms where arm.kind == .seed {
            seedFloor = max(seedFloor, abs(pair(all19, try fitted(nil, arm.seed), labels: data.labels, s).vote.delta))
        }
        let trioFit = try fitted(trio, s.seed)
        note(String(format: "core: the seed floor is %.4f vote AUC; the trio's vote AUC %.4f", seedFloor, trioFit.metrics.imageMajorityAUC))

        func makeRow(_ arm: CoreArm, _ f: Fit) -> CoreArmRow {
            let a = pair(all19, f, labels: data.labels, s), t = pair(trioFit, f, labels: data.labels, s)
            let poolRows = pools(f.majority, images: data.scored.images, cuts: f.cuts)
            let needle: String, distance: String
            switch arm.kind {
            case .reference: needle = Self.needle(t.vote, seedFloor: seedFloor); distance = "reference"
            case .seed: needle = "control"; distance = "control"
            case .trio: needle = "reference"; distance = Self.distance(a.vote, s)
            default: needle = Self.needle(t.vote, seedFloor: seedFloor); distance = Self.distance(a.vote, s)
            }
            return CoreArmRow(arm: arm, features: arm.allowed.map { WarpFeatures.names[$0] }, width: f.width, splitColumns: f.splitColumns,
                              modelSHA256: f.sha256, metrics: f.metrics, calibration: f.calibration,
                              sensor: sensor(f.majority, labels: data.labels, cuts: f.cuts), cameraRealShare: cameraShare(poolRows, s),
                              againstAll19: a, againstTrio: t, pools: poolRows, forwardStep: nil, seconds: f.seconds, needle: needle, distance: distance,
                              qualifies: false)
        }

        var rows: [CoreArmRow] = []
        for arm in arms {
            let f = try fitted(arm.columns, arm.seed)
            let row = makeRow(arm, f)
            rows.append(row)
            note("core: " + PruningStudy.padded(arm.name, 20) + String(format: " %2d columns, vote AUC %.4f (vs trio %+.4f [%+.4f, %+.4f]; vs all19 %+.4f), %@ real %.3f, generated called real %.3f, %.0fs — %@",
                                                                   arm.width, f.metrics.imageMajorityAUC, row.againstTrio.vote.delta, row.againstTrio.vote.low,
                                                                   row.againstTrio.vote.high, row.againstAll19.vote.delta, s.cameraPool, row.cameraRealShare ?? .nan,
                                                                   row.sensor.generatedCalledReal, f.seconds, row.needle))
        }

        // Forward selection from the trio.
        var forward: [CoreForwardStep] = []
        var path: [(columns: [Int], picks: [String])] = [(trio, [])]
        if s.forwardSelection {
            var base = trio, baseFit = trioFit, picks: [String] = []
            var remaining = Array(3..<WarpFeatures.count)
            var step = 0
            while !remaining.isEmpty && step < s.maxForwardSteps {
                step += 1
                var candidates: [CoreForwardCandidate] = []
                var best: (index: Int, column: Int)? = nil
                for c in remaining {
                    let columns = (base + [c]).sorted()
                    let p = pair(baseFit, try fitted(columns, s.seed), labels: data.labels, s)
                    candidates.append(CoreForwardCandidate(feature: WarpFeatures.names[c], columns: columns, vote: p.vote, weighted: p.weighted))
                    if best == nil || p.vote.delta > candidates[best!.index].vote.delta { best = (candidates.count - 1, c) }
                }
                let chosen = candidates[best!.index]
                var stop: String? = nil
                if chosen.vote.low <= 0 { stop = "the best gain's 95% interval holds zero" }
                else if chosen.vote.delta <= seedFloor { stop = "the best gain does not exceed the seed floor" }
                forward.append(CoreForwardStep(step: step, base: base.map { WarpFeatures.names[$0] }, candidates: candidates, best: chosen.feature,
                                               gain: chosen.vote.delta, low: chosen.vote.low, high: chosen.vote.high,
                                               picked: stop == nil ? chosen.feature : nil, stopped: stop))
                note("core: forward step \(step): best \(chosen.feature) " + String(format: "%+.4f [%+.4f, %+.4f]", chosen.vote.delta, chosen.vote.low, chosen.vote.high)
                     + (stop.map { " — stop: \($0)" } ?? " — added"))
                if stop != nil { break }
                base = chosen.columns
                baseFit = try fitted(base, s.seed)
                picks.append(chosen.feature)
                path.append((base, picks))
                remaining.removeAll { $0 == best!.column }
            }
        }
        for (k, step) in path.enumerated() {
            if let i = rows.firstIndex(where: { $0.arm.allowed == step.columns && $0.arm.seed == s.seed && $0.arm.kind != .reference }) {
                rows[i].forwardStep = k
            } else if k > 0 {
                let arm = CoreArm(name: "trio+" + step.picks.joined(separator: "+"), detail: "forward selection's set after step \(k)",
                                  columns: step.columns, seed: s.seed, kind: .forward)
                var row = makeRow(arm, try fitted(step.columns, s.seed))
                row.forwardStep = k
                rows.append(row)
            }
        }

        // R2.
        let reference = goldenInput(rows[0], order: 0)
        var candidates: [GoldenInput] = []
        for (i, row) in rows.enumerated() where ![.reference, .seed].contains(row.arm.kind) {
            let input = goldenInput(row, order: i)
            rows[i].qualifies = qualifies(input, reference: reference, s)
            candidates.append(input)
        }
        let goldenArm = golden(candidates, reference: reference, s)
        note("core: golden (this run): \(goldenArm.name), \(goldenArm.features.joined(separator: ", ")) — \(goldenArm.reason)")

        // The shipped model on the same images.
        var shipped: CoreShipped? = nil
        if let bundle = inputs.bundle, let url = bundle.url(.warpTile), let calibrationURL = bundle.url(.sensorCalibration) {
            let model = try GBDTModel.load(url)
            let contract = try SensorCalibrationContract.decode(Data(contentsOf: calibrationURL), expectedModelSHA256: bundle.sha256(.warpMajoritySensor) ?? "",
                                                                expectedSensorVariant: try SensorCalibrationContract.variant(featureCount: model.featureCount))
            let scores = WarpTrainer.imageScores(model, data.scored)
            let cuts = contract.equivalentCuts()
            let poolRows = pools(scores.majority, images: data.scored.images, cuts: cuts)
            shipped = CoreShipped(sha256: bundle.sha256(.warpTile) ?? "", metrics: WarpTrainer.metrics(model, data.scored), cuts: cuts,
                                  sensor: sensor(scores.majority, labels: data.labels, cuts: cuts), cameraRealShare: cameraShare(poolRows, s), pools: poolRows,
                                  note: "the shipped model and its cuts on the same images; final_mixed is its own training corpus, so these numbers say reliance, not generalization")
        }
        return CoreReport(date: Date(), settings: s, rules: s.rules, partitions: partitions, seedFloor: seedFloor, rows: rows, forward: forward,
                          golden: goldenArm, shipped: shipped, seconds: Date().timeIntervalSince(started))
    }
}
