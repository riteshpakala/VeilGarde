//
//  RedundancyStudy.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Whether what the noiseprint and the fusion head know is already in the warp residual. For
//        each arm (the trio, the golden set, the ten residual features, all 19, the nine raw-tile
//        features) the arm's residual view of every final_mixed image is asked to reconstruct the
//        noiseprint's call and the fusion head's call, and each signal's gain on top of the view
//        is measured. Then the shipped combiner is replayed with and without the noiseprint, to see
//        how many of the calls the noiseprint moves the arm's own sensor call already gets right.
//  PIN:  The rules fixed before the run (ledger decision-96) ride in the report. Each arm's warp model
//        is the core study's (CoreStudy.model) with cuts refit on the validation partition. Second-
//        stage models are the scratch fusion shape, cross-fitted on the held-out partitions: fit on
//        validation and scored on test, fit on test and scored on validation, so no stacked model
//        sees a residual score from an image the warp model trained on. Comparisons are
//        PairedComparison's. Nothing is written but the report.
//

import Foundation
import VeilGardeCore

public struct RedundancySettings: Codable, Sendable, Equatable {
    public var resamples = 1000
    public var seed: UInt64 = 0
    /// RR1: a gain at most this is redundant; a gain past it with an interval above zero is complementary.
    public var gainTolerance = 0.005
    /// RR2: the residual reconstructs a signal's call at a cross-fitted AUC of at least this.
    public var reconstructionBar = 0.90
    public var warpParams: BoostParams? = nil
    public var stageParams = BoostParams(trees: 300, maxDepth: 5, eta: 0.04, subsample: 0.8, colsampleByTree: 0.8, seed: 0)
    public var calibration = CalibrationSettings()
    /// The core study's golden set (nil: no golden arm).
    public var golden: [Int]? = nil
    public var cameraPool = "iphone"

    public init() {}

    public var rules: [String] {
        [
            "RR0. An arm's residual view is its warp model's weighted score and tile vote, its three sharpness values, and the mean and spread over the image's tiles of each feature the model splits on. The warp model is the core study's for that mask (the deployed shape, fit on final_mixed's train partition), its cuts refit on the validation partition.",
            "Every second-stage model is the scratch fusion shape (\(stageParams.trees) trees, depth \(stageParams.maxDepth), η \(stageParams.eta), subsample and colsample 0.8, seed \(stageParams.seed)), cross-fitted on the held-out partitions: fit on validation and scored on test, fit on test and scored on validation, never on an image the warp model trained on.",
            String(format: "RR1. A signal is redundant with the residual under an arm when the AUC it adds on top of the residual view is at most %.3f; complementary when that gain's 95%% interval (%d Poisson resamples, seed %llu) excludes zero and the gain exceeds %.3f; otherwise undetermined.", gainTolerance, resamples, seed, gainTolerance),
            String(format: "RR2. The residual reconstructs a signal when the residual view predicts the signal's call (the noiseprint's P(camera) above 0.5; the fusion head's p above 0.5, the arm's own warp score in its first column) with a cross-fitted AUC of at least %.2f.", reconstructionBar),
            "The decision coverage (the shipped combiner replayed with and without the noiseprint on capture-absent images, and the fusion head's call against the warp lens's own) is descriptive; no rule judges it.",
            "The images are final_mixed, the shipped warp model's and the fusion head's own corpus, so the shipped heads' outputs here say reliance. Their DINOv2 and capture rows are the research's extraction, capture's present flag at its older threshold of 20.",
        ]
    }
}

public struct RedundancyGain: Codable, Sendable, Equatable {
    public var name: String
    public var detail: String
    public var comparison: PairedComparison
    /// RR1: redundant | complementary | undetermined
    public var verdict: String
}

public struct RedundancyReconstruction: Codable, Sendable, Equatable {
    /// noiseprint | fusion
    public var target: String
    public var images: Int
    public var positives: Int
    public var auc: Double
    /// Spearman's ρ between the residual's own score (the vote for the noiseprint, the weighted score for the fusion head) and the signal's.
    public var spearman: Double
    /// RR2.
    public var reconstructed: Bool
}

public struct RedundancyCoverage: Codable, Sendable, Equatable {
    public var captureAbsent: Int
    /// Calls the noiseprint term moves, how many of those it moves to the right label, and how many the arm's sensor call already had right.
    public var noiseprintMoved: Int
    public var noiseprintMovedRight: Int
    public var movedSensorRight: Int
    /// Images where the fusion head's call and the warp lens's own differ, and who is right.
    public var fusionWarpDisagree: Int
    public var fusionRight: Int
    public var warpRight: Int
}

/// The camera pool: the arm's sensor call against the noiseprint's.
public struct RedundancyCamera: Codable, Sendable, Equatable {
    public var images: Int
    public var sensorRealCamera: Int
    public var sensorRealNoCamera: Int
    public var sensorOtherCamera: Int
    public var sensorOtherNoCamera: Int
}

public struct RedundancyArm: Codable, Sendable, Equatable {
    public var name: String
    public var columns: [Int]
    public var features: [String]
    public var cuts: SensorCuts
    public var reconstruction: [RedundancyReconstruction]
    /// Each input set's cross-fitted AUC on the held-out images.
    public var aucs: [String: Double]
    public var gains: [RedundancyGain]
    public var coverage: RedundancyCoverage
    public var camera: RedundancyCamera
    /// RR1 on the noiseprint, and on DINOv2 with capture, each on top of the residual view.
    public var noiseprintVerdict: String
    public var dinoCaptureVerdict: String
    public var seconds: Double
}

public struct RedundancyReport: Codable, Sendable {
    public var date: Date
    public var settings: RedundancySettings
    public var rules: [String]
    public var counts: [String: Int]
    public var arms: [RedundancyArm]
    public var seconds: Double
}

public enum RedundancyStudy {
    public struct Inputs: Sendable {
        public var tiles: URL
        public var store: URL
        /// The scratch store holding the noiseprint shard.
        public var aux: URL
        /// The shipped bundle: the fusion head, the heads and the combiner.
        public var bundle: ModelBundle

        public init(tiles: URL, store: URL, aux: URL, bundle: ModelBundle) {
            self.tiles = tiles
            self.store = store
            self.aux = aux
            self.bundle = bundle
        }
    }

    /// The arms, deduplicated by columns (a golden set equal to another arm is that arm).
    public static func arms(_ s: RedundancySettings) -> [(name: String, columns: [Int])] {
        var out: [(String, [Int])] = [("trio", CoreStudy.trio)]
        if let golden = s.golden { out.append(("golden", golden.sorted())) }
        out += [("residual10", Array(0..<10)), ("all19", Array(0..<WarpFeatures.count)), ("raw9", CoreStudy.rawNine)]
        var seen = Set<[Int]>()
        return out.filter { seen.insert($0.1).inserted }
    }

    /// Spearman's rank correlation, ties given their average rank.
    static func spearman(_ a: [Float], _ b: [Float]) -> Double {
        func ranks(_ v: [Float]) -> [Double] {
            let order = v.indices.sorted { v[$0] < v[$1] }
            var r = [Double](repeating: 0, count: v.count), i = 0
            while i < order.count {
                var j = i
                while j + 1 < order.count && v[order[j + 1]] == v[order[i]] { j += 1 }
                for k in i...j { r[order[k]] = Double(i + j) / 2 }
                i = j + 1
            }
            return r
        }
        let x = ranks(a), y = ranks(b), n = Double(x.count)
        guard n > 1 else { return .nan }
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (u, v) in zip(x, y) { sxy += (u - mx) * (v - my); sxx += (u - mx) * (u - mx); syy += (v - my) * (v - my) }
        return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : .nan
    }

    /// Out-of-fold predictions over `rows`: the model fit on one fold scores the other.
    static func crossFit(_ rows: [Int], fold: (Int) -> Int, x: (Int) -> [Float], y: (Int) -> Float, params: BoostParams) -> [Float] {
        var out = [Float](repeating: .nan, count: rows.count)
        guard let first = rows.first else { return out }
        let width = x(first).count
        for f in 0..<2 {
            let fit = rows.indices.filter { fold(rows[$0]) == f }, scored = rows.indices.filter { fold(rows[$0]) != f }
            guard !fit.isEmpty, !scored.isEmpty else { continue }
            var xs: [Float] = []
            xs.reserveCapacity(fit.count * width)
            for i in fit { xs += x(rows[i]) }
            let model = BoostTrainer.train(BoostDataset(x: xs, y: fit.map { y(rows[$0]) }, features: width), params: params).model
            for i in scored { out[i] = model.predict(x(rows[i])) }
        }
        return out
    }

    /// RR1 on a gain.
    static func verdict(_ c: PairedComparison, _ s: RedundancySettings) -> String {
        if c.delta <= s.gainTolerance { return "redundant" }
        return c.low > 0 ? "complementary" : "undetermined"
    }

    public static func run(_ inputs: Inputs, settings s: RedundancySettings, note: (String) -> Void = { _ in }) throws -> RedundancyReport {
        let started = Date()
        let join = try ResearchJoin.finalMixed(tiles: inputs.tiles, store: inputs.store, aux: inputs.aux)
        let data = CoreStudy.sets(try TileCache(directory: inputs.tiles).load(), leftOut: nil)
        let held = join.indices(in: [.val, .test])
        let images = join.images
        let labels = images.map { Float($0.label) }
        let fold: (Int) -> Int = { images[$0].split == .val ? 0 : 1 }
        var counts = join.counts
        counts["held-out joined"] = held.count
        counts["held-out with a noiseprint"] = held.filter { images[$0].noiseprint.isFinite }.count
        counts["held-out \(s.cameraPool)"] = held.filter { images[$0].pool == s.cameraPool }.count
        note("redundancy: \(images.count) images joined, \(held.count) held out (validation and test)")
        guard let fusionURL = inputs.bundle.url(.fusionHead), let combinerURL = inputs.bundle.url(.combiner) else {
            throw VeilGardeFailure.missing("the bundle has no fusion head or combiner")
        }
        let fusion = try GBDTModel.load(fusionURL)
        let heads = try HeadKind.combinerOrder.map { kind -> LinearHead in
            guard let url = inputs.bundle.url(.head, head: kind) else { throw VeilGardeFailure.missing("the bundle has no \(kind.rawValue) head") }
            return try LinearHead.load(url)
        }
        let combiner = try StackCombiner.load(combinerURL)
        var without = combiner
        without.wNp = nil
        let params = s.warpParams ?? WarpShape.deployed.params
        let call: (Float) -> String = { $0 > 0.5 ? "generated" : "real" }
        let truth: (Int) -> String = { images[$0].label == 1 ? "generated" : "real" }

        var arms: [RedundancyArm] = []
        for (name, columns) in Self.arms(s) {
            let armStarted = Date()
            let model = CoreStudy.model(columns.count == WarpFeatures.count ? nil : columns, seed: s.seed, train: data.train, params: params)
            let sha = ContentHash.sha256Hex(model.encodeXGBoostJSON())
            let cal = try CoreStudy.cuts(validation: data.validation, majority: WarpTrainer.imageScores(model, data.validation).majority, sha256: sha,
                                         featureCount: model.featureCount, settings: s.calibration)
            let cuts = cal.cuts
            let views = ResidualView.all(model, join.tiles, columns: columns)
            let fusionP = images.indices.map { fusion.predict([views[$0].weighted] + images[$0].dinoFusion + images[$0].cap + views[$0].sharp) }

            // RR-A: the residual view reconstructing each signal's call.
            let npRows = held.filter { images[$0].noiseprint.isFinite }
            let npTarget: (Int) -> Float = { images[$0].noiseprint > 0.5 ? 1 : 0 }
            let npOOF = crossFit(npRows, fold: fold, x: { views[$0].vector }, y: npTarget, params: s.stageParams)
            let fuTarget: (Int) -> Float = { fusionP[$0] > 0.5 ? 1 : 0 }
            let fuOOF = crossFit(held, fold: fold, x: { views[$0].vector }, y: fuTarget, params: s.stageParams)
            let npAUC = Metrics.auc(npOOF, npRows.map(npTarget)), fuAUC = Metrics.auc(fuOOF, held.map(fuTarget))
            let reconstruction = [
                RedundancyReconstruction(target: "noiseprint", images: npRows.count, positives: npRows.filter { npTarget($0) == 1 }.count, auc: npAUC,
                                         spearman: spearman(npRows.map { views[$0].vote }, npRows.map { images[$0].noiseprint }), reconstructed: npAUC >= s.reconstructionBar),
                RedundancyReconstruction(target: "fusion", images: held.count, positives: held.filter { fuTarget($0) == 1 }.count, auc: fuAUC,
                                         spearman: spearman(held.map { views[$0].weighted }, held.map { fusionP[$0] }), reconstructed: fuAUC >= s.reconstructionBar),
            ]

            // RR-B: each signal's gain on top of the residual view, and the residual's on top of them.
            let np: (Int) -> [Float] = { [images[$0].noiseprint] }
            let semantic: (Int) -> [Float] = { images[$0].dinoFusion + images[$0].cap }
            let sets: [(String, (Int) -> [Float])] = [
                ("residual", { views[$0].vector }),
                ("residual + noiseprint", { views[$0].vector + np($0) }),
                ("residual + DINOv2 + capture", { views[$0].vector + semantic($0) }),
                ("noiseprint", np),
                ("DINOv2 + capture", semantic),
                ("DINOv2 + capture + noiseprint", { semantic($0) + np($0) }),
                ("everything", { semantic($0) + np($0) + views[$0].vector }),
            ]
            var oof: [String: [Float]] = [:], aucs: [String: Double] = [:]
            let y = held.map { labels[$0] }
            for (setName, x) in sets {
                oof[setName] = crossFit(held, fold: fold, x: x, y: { labels[$0] }, params: s.stageParams)
                aucs[setName] = Metrics.auc(oof[setName]!, y)
            }
            func gain(_ gained: String, _ detail: String, variant: String, reference: String) -> RedundancyGain {
                let c = PairedComparison.measure(reference: oof[reference]!, variant: oof[variant]!, labels: y, resamples: s.resamples, seed: s.seed, call: call)
                return RedundancyGain(name: gained, detail: detail, comparison: c, verdict: verdict(c, s))
            }
            let gains = [
                gain("noiseprint | residual", "the noiseprint added to the residual view", variant: "residual + noiseprint", reference: "residual"),
                gain("DINOv2 + capture | residual", "DINOv2 and the capture values added to the residual view", variant: "residual + DINOv2 + capture", reference: "residual"),
                gain("residual | noiseprint", "the residual view added to the noiseprint", variant: "residual + noiseprint", reference: "noiseprint"),
                gain("residual | DINOv2 + capture", "the residual view added to DINOv2 and capture", variant: "residual + DINOv2 + capture", reference: "DINOv2 + capture"),
                gain("noiseprint | residual + DINOv2 + capture", "the noiseprint added to everything else", variant: "everything", reference: "residual + DINOv2 + capture"),
                gain("residual | DINOv2 + capture + noiseprint", "the residual view added to everything else", variant: "everything", reference: "DINOv2 + capture + noiseprint"),
            ]

            // RR-C: the combiner replayed with and without the noiseprint on capture-absent images.
            var coverage = RedundancyCoverage(captureAbsent: 0, noiseprintMoved: 0, noiseprintMovedRight: 0, movedSensorRight: 0,
                                              fusionWarpDisagree: 0, fusionRight: 0, warpRight: 0)
            for i in held {
                let image = images[i]
                let fusionCall = call(fusionP[i]), warpCall = views[i].weighted > WarpTrainer.decision.threshold ? "generated" : "real"
                if fusionCall != warpCall {
                    coverage.fusionWarpDisagree += 1
                    if fusionCall == truth(i) { coverage.fusionRight += 1 }
                    if warpCall == truth(i) { coverage.warpRight += 1 }
                }
                guard !(image.cap.count > 2 && image.cap[2] > 0.5), image.dinoNorm.first?.isFinite == true else { continue }
                coverage.captureAbsent += 1
                let hp = heads.map { $0.pAI(image.dinoNorm) }
                let withNP = combiner.pool(base: fusionP[i], heads: hp, pairAI: nil, np: image.noiseprint.isFinite ? image.noiseprint : nil)
                let withoutNP = without.pool(base: fusionP[i], heads: hp, pairAI: nil, np: nil)
                guard call(withNP) != call(withoutNP) else { continue }
                coverage.noiseprintMoved += 1
                if call(withNP) == truth(i) { coverage.noiseprintMovedRight += 1 }
                if cuts.call(views[i].vote) == truth(i) { coverage.movedSensorRight += 1 }
            }
            var camera = RedundancyCamera(images: 0, sensorRealCamera: 0, sensorRealNoCamera: 0, sensorOtherCamera: 0, sensorOtherNoCamera: 0)
            for i in held where images[i].pool == s.cameraPool && images[i].noiseprint.isFinite {
                camera.images += 1
                let sensorReal = cuts.call(views[i].vote) == "real", isCamera = images[i].noiseprint > 0.5
                switch (sensorReal, isCamera) {
                case (true, true): camera.sensorRealCamera += 1
                case (true, false): camera.sensorRealNoCamera += 1
                case (false, true): camera.sensorOtherCamera += 1
                case (false, false): camera.sensorOtherNoCamera += 1
                }
            }
            let arm = RedundancyArm(name: name, columns: columns, features: columns.map { WarpFeatures.names[$0] }, cuts: cuts, reconstruction: reconstruction,
                                    aucs: aucs, gains: gains, coverage: coverage, camera: camera, noiseprintVerdict: gains[0].verdict,
                                    dinoCaptureVerdict: gains[1].verdict, seconds: Date().timeIntervalSince(armStarted))
            arms.append(arm)
            note(String(format: "redundancy: %@ — reconstructs the noiseprint at AUC %.3f, the fusion call at %.3f; noiseprint | residual %+.4f (%@), DINOv2 + capture | residual %+.4f (%@); %.0fs",
                        name, npAUC, fuAUC, gains[0].comparison.delta, gains[0].verdict, gains[1].comparison.delta, gains[1].verdict, arm.seconds))
        }
        return RedundancyReport(date: Date(), settings: s, rules: s.rules, counts: counts, arms: arms, seconds: Date().timeIntervalSince(started))
    }
}
