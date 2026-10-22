//
//  CombinerTrainer.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The stack combiner, the combiner revision's pool on the capture-absent branch: a
//        non-negative logistic over the anchor's capped logit (the camera head's), the evidence
//        members' bounded generated evidence (art, blur, human) and the consensus rescue. Evidence
//        adds; none can auto-win and none can invert.
//  PIN:  The reference's atlas combiner, line for line, without the noiseprint and art-pair columns
//        it once carried. Features: la = clip(logit(clip(camera, 1e−4)), ±4); each evidence logit
//        capped at ±2; gen = relu(evidence logits); rescue = relu(−max evidence logit), only while
//        camera < 0.75; the columns are [la, gen_art, gen_blur, gen_human, −rescue]. The fit weights
//        reals ×3 and zeroes the rescue column (the corpus cannot teach it). The rescue weight is
//        then chosen against the protect-real probes: the first of 0.5, 0.8, 1.0, 1.3 under which
//        every probe reads ≤ 0.5 and none above 0.42, else 1.0 (the reference loop never keeps
//        0.0). Caps 4 and 2 and the 0.75 gate are fixed. The anchor is the camera head's prediction
//        on store rows it may have trained on, so its test numbers are in-sample for it. The file
//        is StackCombiner's version 1, the evidence keyed by member name.
//

import Foundation
import VeilGardeCore

public enum CombinerFeatures {
    public static let capAnchor = 4.0
    public static let capHead = 2.0
    public static let gateCeiling = 0.75
    public static let count = 5

    static func logit(_ p: Double, cap: Double) -> Double {
        let c = min(max(p, 1e-4), 1 - 1e-4)
        return min(max(log(c / (1 - c)), -cap), cap)
    }

    /// One row's columns from the camera head's P(AI) and the evidence heads' (art, blur, human).
    public static func row(camera: Double, heads: [Double]) -> [Double] {
        let la = logit(camera, cap: capAnchor)
        let lh = heads.map { logit($0, cap: capHead) }
        let gen = lh.map { max($0, 0) }
        let maxHead = lh.max() ?? 0
        let rescue = camera < gateCeiling ? max(-maxHead, 0) : 0
        return [la] + gen + [-rescue]
    }
}

/// A protect-real probe: an image every combiner must read as real.
public struct CombinerProbe: Codable, Sendable, Equatable {
    public var name: String
    public var camera: Double
    public var heads: [Double]

    public init(name: String, camera: Double, heads: [Double]) {
        self.name = name
        self.camera = camera
        self.heads = heads
    }

    /// The reference USER_REALS (atlas_combiner.py, 2026-07-13: "1" relabeled generated and removed).
    public static let userReals: [CombinerProbe] = [
        CombinerProbe(name: "2", camera: 0.27, heads: [0.95, 0.94, 0.08]),
        CombinerProbe(name: "3", camera: 0.52, heads: [0.99, 0.93, 0.04]),
        CombinerProbe(name: "4", camera: 0.24, heads: [0.01, 0.00, 0.00]),
        CombinerProbe(name: "5", camera: 0.28, heads: [0.06, 0.30, 0.00]),
        CombinerProbe(name: "6", camera: 0.18, heads: [0.94, 0.90, 0.00]),
        CombinerProbe(name: "7", camera: 0.35, heads: [0.02, 0.02, 0.00]),
        CombinerProbe(name: "D72", camera: 0.11, heads: [0.03, 0.00, 0.00]),
    ]
}

public struct CombinerSettings: Codable, Sendable, Equatable {
    public var realsWeight = 3.0
    public var rescueSweep = [0.0, 0.5, 0.8, 1.0, 1.3]
    public var rescueFallback = 1.0
    public var maxProbe = 0.42
    public var probes = CombinerProbe.userReals

    public init() {}
}

public struct CombinerSample: Sendable, Equatable {
    public var id: String
    public var label: Int
    public var camera: Double
    public var heads: [Double]

    public init(id: String, label: Int, camera: Double, heads: [Double]) {
        self.id = id
        self.label = label
        self.camera = camera
        self.heads = heads
    }
}

extension CombinerSample {
    /// The combiner's rows from a store selection: every capture-absent row that has both
    /// embeddings, the camera head's prediction on its camera row (on rows it may have trained on)
    /// and the evidence heads on its dino_norm. Rows keep the selection's order.
    public static func captureAbsent(_ selection: StoreSelection, camera: GBDTModel, heads: [LinearHead]) throws -> [CombinerSample] {
        guard camera.featureCount == CameraRow.width else {
            throw VeilGardeFailure.data("the camera head reads \(camera.featureCount) features, not \(CameraRow.width)")
        }
        var out = [CombinerSample?](repeating: nil, count: selection.count)
        out.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: selection.count) { i in
                let cap = Array(selection.vector(.cap, row: i))
                guard !((cap.count > 2 && cap[2].isFinite ? cap[2] : 0) > 0.5) else { return }     // capture-absent only
                let norm = Array(selection.vector(.dinoNorm, row: i)), fusion = Array(selection.vector(.dinoFusion, row: i))
                guard norm.first?.isFinite == true, fusion.first?.isFinite == true else { return }
                var row = [Float]()
                row.reserveCapacity(CameraRow.width)
                for column in CameraRow.columns { row.append(contentsOf: selection.vector(column, row: i)) }
                slots[i] = CombinerSample(id: selection.rows[i].id, label: selection.rows[i].label, camera: Double(camera.predict(row)),
                                          heads: heads.map { Double($0.pAI(norm)) })
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
    public var testAUCCamera: Double?
    public var testAUCCombined: Double?
    public var testRealFPRCamera: Double?
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
            (probe.name, probability(w0, w, CombinerFeatures.row(camera: probe.camera, heads: probe.heads)))
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

    public static func train(_ samples: [CombinerSample], evidence members: [String] = HeadKind.combinerOrder.map(\.rawValue),
                             settings: CombinerSettings = CombinerSettings(),
                             note: (String) -> Void = { _ in }) throws -> (file: CombinerFile, report: CombinerReport) {
        let isTest = samples.map { StableSplit.isHoldout($0.id, salt: "combiner:v1", fraction: 0.2) }
        let train = samples.indices.filter { !isTest[$0] }, test = samples.indices.filter { isTest[$0] }
        guard train.count >= 50, Set(train.map { samples[$0].label }).count == 2 else {
            throw VeilGardeFailure.data("the combiner needs ≥ 50 capture-absent rows of both classes to fit; have \(train.count)")
        }
        guard members.count == 3 else { throw VeilGardeFailure.usage("the combiner pools three evidence members, not \(members.count)") }
        let features = samples.map { CombinerFeatures.row(camera: $0.camera, heads: $0.heads) }
        note("combiner: \(train.count) train rows, \(test.count) test rows, reals ×\(settings.realsWeight)")
        let fit = fitWeights(features: train.map { features[$0] }, labels: train.map { samples[$0].label }, realsWeight: settings.realsWeight)
        var w = fit.w
        let (rescue, sweep) = chooseRescue(w0: fit.w0, w: w, settings: settings)
        w[4] = rescue

        var aucCamera: Double? = nil, aucCombined: Double? = nil, fprCamera: Double? = nil, fprCombined: Double? = nil
        if !test.isEmpty {
            let y = test.map { Float(samples[$0].label) }
            let pb = test.map { Float(samples[$0].camera) }, pc = test.map { Float(probability(fit.w0, w, features[$0])) }
            aucCamera = Metrics.auc(pb, y)
            aucCombined = Metrics.auc(pc, y)
            let reals = test.indices.filter { y[$0] == 0 }
            if !reals.isEmpty {
                fprCamera = Double(reals.filter { pb[$0] > 0.5 }.count) / Double(reals.count)
                fprCombined = Double(reals.filter { pc[$0] > 0.5 }.count) / Double(reals.count)
            }
        }
        let file = CombinerFile(w0: fit.w0, anchor: .init(w: w[0]), evidence: zip(members, w[1...3]).map { CombinerFile.Evidence(member: $0, w: $1) },
                                rescue: .init(w: w[4]),
                                note: "Evidence pooling around the camera anchor (capture-absent branch only), fitted on the features-only store: "
                                    + "non-negative weights, reals ×\(settings.realsWeight), the rescue weight chosen against the protect-real probes.")
        let report = CombinerReport(train: train.count, test: test.count, fitted: [fit.w0] + fit.w, sweep: sweep, rescue: rescue,
                                    probes: probeScores(fit.w0, w, settings.probes),
                                    testAUCCamera: aucCamera, testAUCCombined: aucCombined, testRealFPRCamera: fprCamera, testRealFPRCombined: fprCombined,
                                    note: "the test rows are a 20% hash holdout of the combiner's rows (StableSplit combiner:v1); "
                                        + "the anchor is the camera head's prediction, in-sample for the head on rows it trained on")
        return (file, report)
    }
}
