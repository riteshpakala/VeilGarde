//
//  CalibrationTrainer.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The camera-sensor score's calibration: the majority fraction (the share of 32-px tiles
//        the sensor model reads above 0.5) mapped by Platt scaling to a probability, the
//        operating threshold chosen on held-out validation images, and the contract that binds
//        both to the sensor model's bytes.
//  PIN:  the reference campaign's Stage 04 (campaign_stages.py) step for step, with hash
//        partitions in place of sklearn's shuffles: validation images split 65/35 by
//        StableSplit("platt:v1:" + stem), stratified by label; at least 25 images of each class
//        to fit and 15 to choose the threshold. Platt is a two-parameter logistic fit on
//        logit(clip(f, 1e−6, 1 − 1e−6)) at sklearn's C = 1e6, solved exactly. It ships only when
//        its 5-fold cross-fitted probabilities do not worsen the Brier score by more than 0.002
//        or the log loss by more than 0.005 over the identity (both clipped at 1e−7); otherwise
//        the identity ships. The threshold is choose_operating_threshold verbatim: every distinct
//        probability (and 0, 1) is a candidate, feasible when the real false-positive rate under
//        `p > t` is at most 0.10, the best generated recall wins, ties go to the candidate
//        nearest 0.5 and then to the higher. The band is 0.04.
//

import Foundation
import VeilGardeCore

public enum Platt {
    /// The two-parameter fit on the clipped logit of `p`.
    public static func fit(labels: [Int], probabilities p: [Double]) -> SensorPlattPayload {
        let x = p.map(logit)
        let fit = LogisticNewton.fit(x: x, y: labels.map(Double.init), d: 1, C: 1e6, tolerance: 1e-10)
        return SensorPlattPayload(coef: fit.coef[0], intercept: fit.intercept)
    }

    public static func apply(_ p: [Double], _ payload: SensorPlattPayload) -> [Double] {
        p.map { 1 / (1 + exp(-(payload.coef * logit($0) + payload.intercept))) }
    }

    static func logit(_ p: Double) -> Double {
        let c = min(max(p, 1e-6), 1 - 1e-6)
        return log(c / (1 - c))
    }
}

public enum OperatingThreshold {
    public struct Choice: Codable, Sendable, Equatable {
        public var threshold: Double
        public var generatedRecall: Double
        public var maxRealFPR: Double
    }

    /// choose_operating_threshold: the best recall with real FPR ≤ `maxRealFPR` under `p > t`.
    public static func choose(labels: [Int], probabilities p: [Double], maxRealFPR: Double) throws -> Choice {
        var candidates = Array(Set([0.0, 1.0] + p)).sorted()
        candidates = candidates.filter(\.isFinite)
        let reals = labels.filter { $0 == 0 }.count, gens = labels.count - reals
        var best: (recall: Double, nearness: Double, threshold: Double)? = nil
        for t in candidates {
            var fp = 0, tp = 0
            for (v, y) in zip(p, labels) where v > t { if y == 0 { fp += 1 } else { tp += 1 } }
            guard reals > 0 else { continue }
            let fpr = Double(fp) / Double(reals)
            let recall = gens > 0 ? Double(tp) / Double(gens) : .nan
            guard fpr <= maxRealFPR else { continue }
            let key = (recall, -abs(t - 0.5), t)
            if let b = best {
                if (key.0, key.1, key.2) > (b.recall, b.nearness, b.threshold) { best = key }
            } else { best = key }
        }
        guard let best else { throw VeilGardeFailure.data("no validation threshold satisfies the real-FPR ceiling \(maxRealFPR)") }
        return Choice(threshold: best.threshold, generatedRecall: best.recall, maxRealFPR: maxRealFPR)
    }
}

public struct CalibrationSettings: Codable, Sendable, Equatable {
    public var maxRealFPR = 0.10
    public var band = 0.04
    public var thresholdFraction = 0.35
    public var minFitClassImages = 25
    public var minThresholdClassImages = 15
    public var maxBrierDelta = 0.002
    public var maxLogLossDelta = 0.005
    public var folds = 5

    public init() {}
}

public struct CalibrationReport: Codable, Sendable, Equatable {
    public struct Scores: Codable, Sendable, Equatable { public var brier: Double; public var logLoss: Double }
    public var fitImages: [String: Int]
    public var thresholdImages: [String: Int]
    public var platt: SensorPlattPayload
    public var crossFitFolds: Int
    public var identity: Scores?
    public var crossFitted: Scores?
    public var plattQualifies: Bool
    public var calibration: SensorCalibrationTransform
    public var operating: OperatingThreshold.Choice
}

public enum CalibrationTrainer {
    public struct Sample: Sendable { public var key: String; public var label: Int; public var fraction: Double
        public init(key: String, label: Int, fraction: Double) { self.key = key; self.label = label; self.fraction = fraction } }

    public static func fit(_ samples: [Sample], settings: CalibrationSettings = CalibrationSettings(), sensorModelSHA256: String,
                           sensorVariant: String) throws -> (file: SensorCalibrationFile, report: CalibrationReport) {
        var fit: [Sample] = [], hold: [Sample] = []
        for label in [0, 1] {
            let members = samples.filter { $0.label == label }
                .sorted { StableSplit.unit($0.key, salt: "platt:v1") < StableSplit.unit($1.key, salt: "platt:v1") }
            let held = Int((Double(members.count) * settings.thresholdFraction).rounded())
            hold += members.prefix(held)
            fit += members.dropFirst(held)
        }
        func counts(_ s: [Sample]) -> [String: Int] { ["real": s.filter { $0.label == 0 }.count, "generated": s.filter { $0.label == 1 }.count] }
        let fitCounts = counts(fit), holdCounts = counts(hold)
        guard fitCounts.values.allSatisfy({ $0 >= settings.minFitClassImages }), holdCounts.values.allSatisfy({ $0 >= settings.minThresholdClassImages }) else {
            throw VeilGardeFailure.data("calibration needs ≥ \(settings.minFitClassImages) images per class to fit and ≥ \(settings.minThresholdClassImages) to choose the threshold; have fit \(fitCounts), threshold \(holdCounts)")
        }
        let payload = Platt.fit(labels: fit.map(\.label), probabilities: fit.map(\.fraction))

        // The cross-fitted gate: Platt must not worsen calibration inside the fit partition.
        let k = min(settings.folds, fitCounts.values.min() ?? 0)
        var identity: CalibrationReport.Scores? = nil, crossed: CalibrationReport.Scores? = nil
        var qualifies = false
        if k >= 2 {
            let fold = HashFolds.stratified(keys: fit.map(\.key), labels: fit.map(\.label), k: k, salt: "platt-fold:v1")
            var outOfFold = [Double](repeating: 0, count: fit.count)
            for f in 0..<k {
                let train = fit.indices.filter { fold[$0] != f }, held = fit.indices.filter { fold[$0] == f }
                let p = Platt.fit(labels: train.map { fit[$0].label }, probabilities: train.map { fit[$0].fraction })
                for (i, v) in zip(held, Platt.apply(held.map { fit[$0].fraction }, p)) { outOfFold[i] = v }
            }
            let y = fit.map(\.label)
            identity = scores(y, fit.map(\.fraction))
            crossed = scores(y, outOfFold)
            qualifies = crossed!.brier - identity!.brier <= settings.maxBrierDelta && crossed!.logLoss - identity!.logLoss <= settings.maxLogLossDelta
        }
        let transform: SensorCalibrationTransform = qualifies ? .platt : .identity
        let selected = qualifies ? Platt.apply(hold.map(\.fraction), payload) : hold.map(\.fraction)
        let operating = try OperatingThreshold.choose(labels: hold.map(\.label), probabilities: selected, maxRealFPR: settings.maxRealFPR)
        let file = SensorCalibrationFile(sensorVariant: sensorVariant, sensorModelSHA256: sensorModelSHA256, calibration: transform,
                                         plattPayload: qualifies ? payload : nil, decisionThreshold: operating.threshold, uncertainBand: settings.band)
        let report = CalibrationReport(fitImages: fitCounts, thresholdImages: holdCounts, platt: payload, crossFitFolds: k,
                                       identity: identity, crossFitted: crossed, plattQualifies: qualifies, calibration: transform, operating: operating)
        return (file, report)
    }

    /// Brier and log loss with the reference metric_bundle's clip (1e−7).
    static func scores(_ y: [Int], _ p: [Double]) -> CalibrationReport.Scores {
        var brier = 0.0, loss = 0.0
        for (yi, pi) in zip(y, p) {
            let c = min(max(pi, 1e-7), 1 - 1e-7)
            brier += (c - Double(yi)) * (c - Double(yi))
            loss -= yi == 1 ? log(c) : log(1 - c)
        }
        let n = Double(max(1, y.count))
        return .init(brier: brier / n, logLoss: loss / n)
    }
}
