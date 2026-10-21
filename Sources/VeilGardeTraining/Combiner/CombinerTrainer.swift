//
//  CombinerTrainer.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The stack combiner, the pooled verdict on the capture-absent branch: a non-negative
//        logistic over the base's capped logit, the heads' bounded generated evidence (the art
//        logit adjudicated by the art-pair head) and the consensus rescue. Heads add evidence; none
//        can auto-win and none can invert.
//  PIN:  The reference's atlas combiner (v3), line for line, without the noiseprint column it
//        carried until 2026-10-21. Features: lb = clip(logit(clip(base, 1e−4)), ±4); each head's
//        logit capped at ±2, the art logit min(l_art, l_pair) (a missing pair reads 1.0, no
//        adjudication); gen = relu(head logits); rescue = relu(−max head logit), only while
//        base < 0.75; the columns are [lb, gen_art, gen_blur, gen_human, −rescue]. The fit weights
//        reals ×3 and zeroes the rescue column (the corpus cannot teach it). The rescue weight is
//        then chosen against the protect-real probes: the first of 0.5, 0.8, 1.0, 1.3 under which
//        every probe reads ≤ 0.5 and none above 0.42, else 1.0 (the reference loop never keeps
//        0.0). Caps 4 and 2 and the 0.75 gate are fixed. The base is the fusion head's prediction
//        on store rows it may have trained on, so the base's test numbers are in-sample for it,
//        unless `baseFolds` asks for out-of-fold predictions: each row's base from a head refit
//        without that row's fold, which a high-capacity head needs, since in-sample it reads its
//        own training rows near-perfectly and the fit gives the specialist heads no weight.
//

import Foundation
import VeilGardeCore

public enum CombinerFeatures {
    public static let capBase = 4.0
    public static let capHead = 2.0
    public static let gateCeiling = 0.75
    public static let count = 5

    static func logit(_ p: Double, cap: Double) -> Double {
        let c = min(max(p, 1e-4), 1 - 1e-4)
        return min(max(log(c / (1 - c)), -cap), cap)
    }

    /// One row's columns from the base probability, the three heads' P(generated) (art, blur,
    /// human) and the art-pair head's P(AI art).
    public static func row(base: Double, heads: [Double], pair: Double?) -> [Double] {
        let lb = logit(base, cap: capBase)
        var lh = heads.map { logit($0, cap: capHead) }
        lh[0] = min(lh[0], logit(pair ?? 1.0, cap: capHead))
        let gen = lh.map { max($0, 0) }
        let maxHead = lh.max() ?? 0
        let rescue = base < gateCeiling ? max(-maxHead, 0) : 0
        return [lb] + gen + [-rescue]
    }
}

/// A protect-real probe: an image every combiner must read as real.
public struct CombinerProbe: Codable, Sendable, Equatable {
    public var name: String
    public var base: Double
    public var heads: [Double]
    public var pair: Double?

    public init(name: String, base: Double, heads: [Double], pair: Double? = nil) {
        self.name = name
        self.base = base
        self.heads = heads
        self.pair = pair
    }

    /// The reference USER_REALS (atlas_combiner.py, 2026-07-13: "1" relabeled generated and removed).
    public static let userReals: [CombinerProbe] = [
        CombinerProbe(name: "2", base: 0.27, heads: [0.95, 0.94, 0.08]),
        CombinerProbe(name: "3", base: 0.52, heads: [0.99, 0.93, 0.04]),
        CombinerProbe(name: "4", base: 0.24, heads: [0.01, 0.00, 0.00]),
        CombinerProbe(name: "5", base: 0.28, heads: [0.06, 0.30, 0.00]),
        CombinerProbe(name: "6", base: 0.18, heads: [0.94, 0.90, 0.00]),
        CombinerProbe(name: "7", base: 0.35, heads: [0.02, 0.02, 0.00]),
        CombinerProbe(name: "D72", base: 0.11, heads: [0.03, 0.00, 0.00], pair: 0.91),
    ]
}

public struct CombinerSettings: Codable, Sendable, Equatable {
    public var realsWeight = 3.0
    public var rescueSweep = [0.0, 0.5, 0.8, 1.0, 1.3]
    public var rescueFallback = 1.0
    public var maxProbe = 0.42
    public var probes = CombinerProbe.userReals
    /// Nil: the base is the fusion head's in-sample prediction. k: each row's base is the
    /// prediction of a head refit without that row's fold, k folds (OutOfFoldBase).
    public var baseFolds: Int? = nil

    public init() {}
}

public struct CombinerSample: Sendable, Equatable {
    public var id: String
    public var label: Int
    public var base: Double
    public var heads: [Double]
    public var pair: Double?

    public init(id: String, label: Int, base: Double, heads: [Double], pair: Double?) {
        self.id = id
        self.label = label
        self.base = base
        self.heads = heads
        self.pair = pair
    }
}

extension CombinerSample {
    /// The combiner's rows from a store selection: every capture-absent row that has both
    /// embeddings, with `base` on its fusion vector in the base's own layout (the head's prediction
    /// on rows it may have trained on), and the three heads and the art-pair head on its dino_norm.
    /// Rows keep the selection's order.
    public static func captureAbsent(_ selection: StoreSelection, base: GBDTModel, heads: [LinearHead], pair: LinearHead?) throws -> [CombinerSample] {
        let columns = try FusionLayout.of(width: base.featureCount).columns
        return captureAbsent(selection, heads: heads, pair: pair) { i in
            var row = [Float]()
            for column in columns { row.append(contentsOf: selection.vector(column, row: i)) }
            return Double(base.predict(row))
        }
    }

    /// The same rows, each row's base read from out-of-fold predictions by id; a row without one is skipped.
    public static func captureAbsent(_ selection: StoreSelection, outOfFold: [String: Double], heads: [LinearHead], pair: LinearHead?) -> [CombinerSample] {
        captureAbsent(selection, heads: heads, pair: pair) { outOfFold[selection.rows[$0].id] }
    }

    static func captureAbsent(_ selection: StoreSelection, heads: [LinearHead], pair: LinearHead?,
                              base: @escaping @Sendable (Int) -> Double?) -> [CombinerSample] {
        var out = [CombinerSample?](repeating: nil, count: selection.count)
        out.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: selection.count) { i in
                let cap = Array(selection.vector(.cap, row: i))
                guard !((cap.count > 2 && cap[2].isFinite ? cap[2] : 0) > 0.5) else { return }     // capture-absent only
                let norm = Array(selection.vector(.dinoNorm, row: i)), fusion = Array(selection.vector(.dinoFusion, row: i))
                guard norm.first?.isFinite == true, fusion.first?.isFinite == true, let b = base(i) else { return }
                slots[i] = CombinerSample(id: selection.rows[i].id, label: selection.rows[i].label, base: b,
                                          heads: heads.map { Double($0.pAI(norm)) }, pair: pair.map { Double($0.pAI(norm)) })
            }
        }
        return out.compactMap { $0 }
    }
}

public struct CombinerReport: Codable, Sendable, Equatable {
    public struct SweepRow: Codable, Sendable, Equatable { public var rescue: Double; public var probesReal: Int; public var maxProbe: Double }
    public var train: Int
    public var test: Int
    public var fitted: [Double]
    public var sweep: [SweepRow]
    public var rescue: Double
    public var probes: [String: Double]
    public var testAUCBase: Double?
    public var testAUCCombined: Double?
    public var testRealFPRBase: Double?
    public var testRealFPRCombined: Double?
    public var note: String
}

public enum CombinerTrainer {
    /// The bounded fit on feature rows: (w0, the five weights) with the rescue column zeroed.
    public static func fitWeights(features: [[Double]], labels: [Int], realsWeight: Double) -> (w0: Double, w: [Double]) {
        let m = CombinerFeatures.count
        var flat = [Double]()
        flat.reserveCapacity(features.count * m)
        for row in features { var r = row; r[4] = 0; flat.append(contentsOf: r) }
        let theta = BoundedLogistic.fit(f: flat, y: labels.map(Double.init), m: m, sampleWeight: labels.map { $0 == 0 ? realsWeight : 1 })
        var w = Array(theta[1...])
        w[4] = 0
        return (theta[0], w)
    }

    static func probability(_ w0: Double, _ w: [Double], _ row: [Double]) -> Double {
        1 / (1 + exp(-(w0 + zip(w, row).reduce(0) { $0 + $1.0 * $1.1 })))
    }

    public static func probeScores(_ w0: Double, _ w: [Double], _ probes: [CombinerProbe]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: probes.map { probe in
            (probe.name, probability(w0, w, CombinerFeatures.row(base: probe.base, heads: probe.heads, pair: probe.pair)))
        })
    }

    /// The rescue weight, by the reference sweep, and the sweep's rows.
    public static func chooseRescue(w0: Double, w: [Double], settings: CombinerSettings) -> (rescue: Double, sweep: [CombinerReport.SweepRow]) {
        var chosen = 0.0
        var rows: [CombinerReport.SweepRow] = []
        for candidate in settings.rescueSweep {
            var ww = w
            ww[4] = candidate
            let scores = probeScores(w0, ww, settings.probes)
            let real = scores.values.filter { $0 <= 0.5 }.count
            let top = scores.values.max() ?? 0
            rows.append(.init(rescue: candidate, probesReal: real, maxProbe: top))
            if real == settings.probes.count && top <= settings.maxProbe && chosen == 0 { chosen = candidate }
        }
        return (chosen != 0 ? chosen : settings.rescueFallback, rows)
    }

    public static func train(_ samples: [CombinerSample], settings: CombinerSettings = CombinerSettings(),
                             note: (String) -> Void = { _ in }) throws -> (file: CombinerFile, report: CombinerReport) {
        let isTest = samples.map { StableSplit.isHoldout($0.id, salt: "combiner:v1", fraction: 0.2) }
        let train = samples.indices.filter { !isTest[$0] }, test = samples.indices.filter { isTest[$0] }
        guard train.count >= 50, Set(train.map { samples[$0].label }).count == 2 else {
            throw VeilGardeFailure.data("the combiner needs ≥ 50 capture-absent rows of both classes to fit; have \(train.count)")
        }
        let features = samples.map { CombinerFeatures.row(base: $0.base, heads: $0.heads, pair: $0.pair) }
        note("combiner: \(train.count) train rows, \(test.count) test rows, reals ×\(settings.realsWeight)")
        let fit = fitWeights(features: train.map { features[$0] }, labels: train.map { samples[$0].label }, realsWeight: settings.realsWeight)
        var w = fit.w
        let (rescue, sweep) = chooseRescue(w0: fit.w0, w: w, settings: settings)
        w[4] = rescue

        var aucBase: Double? = nil, aucCombined: Double? = nil, fprBase: Double? = nil, fprCombined: Double? = nil
        if !test.isEmpty {
            let y = test.map { Float(samples[$0].label) }
            let pb = test.map { Float(samples[$0].base) }, pc = test.map { Float(probability(fit.w0, w, features[$0])) }
            aucBase = Metrics.auc(pb, y)
            aucCombined = Metrics.auc(pc, y)
            let reals = test.indices.filter { y[$0] == 0 }
            if !reals.isEmpty {
                fprBase = Double(reals.filter { pb[$0] > 0.5 }.count) / Double(reals.count)
                fprCombined = Double(reals.filter { pc[$0] > 0.5 }.count) / Double(reals.count)
            }
        }
        // The art-pair adjudicates only when the candidate trained one; the shipped recipe does not.
        let adjudicated = samples.contains { $0.pair != nil }
        var file = CombinerFile(w0: fit.w0, wBase: w[0], wGen: Array(w[1...3]), wRescue: w[4],
                                note: "VeilGarde v3 asymmetric evidence pooling (capture-absent branch only), fitted on the features-only store: "
                                    + "non-negative weights, reals ×\(settings.realsWeight), "
                                    + (adjudicated ? "the art logit adjudicated by the art-pair head, " : "")
                                    + (settings.baseFolds.map { "the base out-of-fold over \($0) folds, " } ?? "")
                                    + "the rescue weight chosen against the protect-real probes.")
        file.pairAdjudicates = adjudicated
        let report = CombinerReport(train: train.count, test: test.count, fitted: [fit.w0] + fit.w, sweep: sweep, rescue: rescue,
                                    probes: probeScores(fit.w0, w, settings.probes),
                                    testAUCBase: aucBase, testAUCCombined: aucCombined, testRealFPRBase: fprBase, testRealFPRCombined: fprCombined,
                                    note: "the test rows are a 20% hash holdout of the combiner's rows (StableSplit combiner:v1); "
                                        + (settings.baseFolds.map { "the base is out-of-fold: each row's prediction by a fusion head refit without its fold (\($0) folds, StableSplit fusion-oof:v1)" }
                                           ?? "the base is the fusion head's prediction, in-sample for the head on rows it trained on"))
        return (file, report)
    }
}
