//
//  HeadTrainer.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The specialist heads: one logistic regression per head on the store's dino_norm column
//        (DINOv2 CLS after the 360×640 resize), standardized, fitted to that head's positives
//        against its negatives, measured on held-out sources, and admitted only when it leaves
//        calm real photos alone.
//  PIN:  atlas_heads_store.py's recipe: usable rows are (positive or negative) and not golden and
//        carry dino_norm; the split is HeadSplit.heads (source-disjoint 25%); a head needs ≥ 50
//        training and ≥ 10 test rows; StandardScaler then LogisticRegression (C 0.5, balanced
//        for the atlas heads), solved to sklearn's optimum. The anchors are golden real rows;
//        `block@t` is the share of them the head reads above t. Admission (the heads' promote script,
//        atlas heads only): block@0.8 ≤ 0.10 on golden reals whose path does not contain "bsky".
//        The screenshot head needs screenshot rows and the semantic-tile head needs patch
//        tokens; the store holds neither, so both are refused with the reason.
//

import Foundation
import VeilGardeCore

/// Which store rows a head takes as positives or negatives.
public struct RowFilter: Codable, Sendable, Equatable {
    public var label: Int
    public var category: String?
    public var source: String?

    public init(label: Int, category: String? = nil, source: String? = nil) {
        self.label = label
        self.category = category
        self.source = source
    }

    public func matches(_ row: FeatureRow) -> Bool {
        row.label == label && (category.map { $0 == row.category } ?? true) && (source.map { $0 == (row.source ?? "") } ?? true)
    }

    public static func generated(_ category: String) -> RowFilter { RowFilter(label: 1, category: category) }
    public static func real(_ category: String) -> RowFilter { RowFilter(label: 0, category: category) }
    public static let allReal = RowFilter(label: 0)

    public var summary: String {
        (label == 1 ? "generated" : "real") + (category.map { " \($0)" } ?? (label == 0 ? " (every category)" : "")) + (source.map { " from \($0)" } ?? "")
    }
}

public struct HeadSettings: Codable, Sendable, Equatable {
    public var C = 0.5
    public var classWeight: ClassWeight = .balanced
    public var version = "cand"
    public var admission = true
    public var threshold = 0.5
    public var fireThreshold: Double? = 0.8
    public var minTrain = 50
    public var minTest = 10

    public init() {}
}

public struct HeadReport: Codable, Sendable, Equatable {
    public var kind: HeadKind
    public var positives: Int
    public var negatives: Int
    public var train: Int
    public var test: Int
    public var split: HeadSplit.Basis
    public var testAUC: Double
    public var anchors: Int
    public var anchorBlock05: Double?
    public var anchorBlock08: Double?
    public var nsfwRealBlock05: Double?
    public var admissionAnchors: Int
    public var admissionBlock08: Double?
    public var admitted: Bool?
    public var iterations: Int
    public var seconds: Double
    /// The parent's head for this kind, scored on the same test rows and anchors.
    public var parent: ParentScores?

    public struct ParentScores: Codable, Sendable, Equatable {
        public var testAUC: Double
        public var anchorBlock08: Double?
        public var admissionBlock08: Double?
    }
}

public enum HeadTrainer {
    /// Why a head cannot be trained from a features-only store, or nil.
    public static func refusal(_ kind: HeadKind, categories: Set<String>) -> String? {
        switch kind {
        case .semtile: return "the semantic-tile head trains on DINOv2 patch tokens, which the store does not keep"
        case .screenshot where !categories.contains("screenshot"):
            return "the store holds no screenshot rows (category \"screenshot\"); the screenshot head trains on screenshot real/generated pairs"
        default: return nil
        }
    }

    /// The file name a trained head ships as (the shipped spellings).
    public static func fileName(_ kind: HeadKind, version: String) -> String {
        switch kind {
        case .artPair: return "art_pair_\(version).json"
        default: return "\(kind.rawValue)_dinov2_\(version).json"
        }
    }

    public static func modelName(_ kind: HeadKind) -> String {
        kind == .artPair ? "art_pair" : "\(kind.rawValue)_dinov2"
    }

    public static func train(_ kind: HeadKind, positives: RowFilter, negatives: RowFilter, settings: HeadSettings,
                             store: StoreSelection, parent: LinearHead? = nil, note: (String) -> Void = { _ in }) throws -> (file: HeadFile, report: HeadReport) {
        let started = Date()
        let d = FeatureColumn.dinoNorm.width
        guard let x = store.columns[.dinoNorm] else { throw VeilGardeFailure.internalError("the selection has no dino_norm column") }
        let valid = (0..<store.count).map { x[$0 * d].isFinite }
        var use: [Int] = []
        var npos = 0, nneg = 0
        for i in 0..<store.count where valid[i] && !store.rows[i].golden {
            let r = store.rows[i]
            if positives.matches(r) { use.append(i); npos += 1 } else if negatives.matches(r) { use.append(i); nneg += 1 }
        }
        let split = HeadSplit.heads(ids: use.map { store.rows[$0].id }, sources: use.map { store.rows[$0].source ?? "" }, labels: use.map { store.rows[$0].label })
        let train = zip(use, split.isTest).filter { !$0.1 }.map(\.0), test = zip(use, split.isTest).filter { $0.1 }.map(\.0)
        guard train.count >= settings.minTrain, test.count >= settings.minTest else {
            throw VeilGardeFailure.data("\(kind.rawValue): too few store rows (train \(train.count), test \(test.count); need ≥ \(settings.minTrain) and ≥ \(settings.minTest))")
        }
        note("head \(kind.rawValue): \(npos) positives (\(positives.summary)), \(nneg) negatives (\(negatives.summary)); \(train.count) train, \(test.count) test by \(split.basis.rawValue)")
        let scaler = StandardScaler.fit(x, d: d, rows: train)
        let label: (Int) -> Double = { Double(store.rows[$0].label) }
        let fit = LogisticNewton.fit(x: scaler.transform(x, d: d, rows: train), y: train.map(label), d: d, C: settings.C, classWeight: settings.classWeight)

        func probabilities(_ rows: [Int]) -> [Float] {
            let z = scaler.transform(x, d: d, rows: rows)
            return (0..<rows.count).map { Float(fit.probability(z[($0 * d)..<(($0 + 1) * d)])) }
        }
        func block(_ p: [Float], _ t: Float) -> Double? { p.isEmpty ? nil : Double(p.filter { $0 > t }.count) / Double(p.count) }
        let pTest = probabilities(test)
        let auc = Metrics.auc(pTest, test.map { Float(store.rows[$0].label) })
        let anchors = (0..<store.count).filter { store.rows[$0].golden && store.rows[$0].label == 0 && valid[$0] }
        let pAnchors = probabilities(anchors)
        let admissionRows = anchors.filter { !store.rows[$0].path.contains("bsky") }
        let pAdmission = probabilities(admissionRows)
        let nsfwReal = test.filter { store.rows[$0].nsfw && store.rows[$0].label == 0 }
        let admissionBlock = block(pAdmission, 0.8)
        let admitted: Bool? = settings.admission ? (admissionBlock.map { $0 <= 0.10 } ?? false) : nil

        let file = HeadFile(model: modelName(kind), normalizeSize: [360, 640], threshold: settings.threshold,
                            fireThreshold: kind == .artPair ? nil : settings.fireThreshold, scalerMean: scaler.mean, scalerScale: scaler.scale,
                            coef: fit.coef, intercept: fit.intercept,
                            note: "VeilGarde \(kind.rawValue) head, trained from the features-only store: \(positives.summary) against \(negatives.summary), "
                                + "split \(split.basis.rawValue)-disjoint, C \(settings.C), class weight \(settings.classWeight.rawValue), golden anchors held out.")
        var parentScores: HeadReport.ParentScores? = nil
        if let parent {
            func scored(_ rows: [Int]) -> [Float] { rows.map { parent.pAI(Array(x[($0 * d)..<(($0 + 1) * d)])) } }
            parentScores = .init(testAUC: Metrics.auc(scored(test), test.map { Float(store.rows[$0].label) }),
                                 anchorBlock08: block(scored(anchors), 0.8), admissionBlock08: block(scored(admissionRows), 0.8))
        }
        let report = HeadReport(kind: kind, positives: npos, negatives: nneg, train: train.count, test: test.count, split: split.basis, testAUC: auc,
                                anchors: anchors.count, anchorBlock05: block(pAnchors, 0.5), anchorBlock08: block(pAnchors, 0.8),
                                nsfwRealBlock05: block(probabilities(nsfwReal), 0.5), admissionAnchors: admissionRows.count,
                                admissionBlock08: admissionBlock, admitted: admitted, iterations: fit.iterations, seconds: Date().timeIntervalSince(started),
                                parent: parentScores)
        return (file, report)
    }
}
