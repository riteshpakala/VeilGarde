//
//  Splits.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The source-disjoint split the heads are held out by.
//  PIN:  The head split is atlas_heads_store.py's, draw for draw: with at least four distinct
//        (non-empty) sources among the usable rows, the sorted sources are shuffled by CPython's
//        random.Random(0) and the first max(1, n // 4) are the test sources; otherwise the sorted
//        unique row ids are shuffled the same way and the first max(1, n // 4) ids are the test
//        rows. One addition: a source split whose test (or training) rows hold one class, where
//        sklearn's roc_auc_score raises, takes the id split instead (on the seed store this happens for
//        the art head: every generated-art source lands in training). Folds and partitions elsewhere hash the row key (StableSplit), so they never
//        depend on row order.
//

import Foundation
import VeilGardeCore

public enum HeadSplit {
    public enum Basis: String, Codable, Sendable {
        case sources
        case ids
        /// The source split left a class out; the id split instead.
        case idsAfterOneClassSources = "ids (the source split left a class out)"
    }

    public struct HeadSplit: Sendable, Equatable {
        /// Per row (of the rows passed in): whether it is a test row.
        public var isTest: [Bool]
        public var basis: Basis
        /// The test sources (basis .sources) or the count of test ids (basis .ids, as one string).
        public var testKeys: [String]
    }

    /// atlas_heads_store.py's split over the usable rows' ids and sources. With `labels`, a source
    /// split that leaves a class out of the test or the training rows (where sklearn's roc_auc_score
    /// raises) falls back to the id split, its own fallback for too few sources.
    public static func heads(ids: [String], sources: [String], labels: [Int]? = nil) -> HeadSplit {
        let distinct = Array(Set(sources.filter { !$0.isEmpty })).sorted(by: pythonOrder)
        if distinct.count >= 4 {
            var shuffled = distinct
            var rng = PythonRandom(seed: 0)
            rng.shuffle(&shuffled)
            let test = Set(shuffled.prefix(max(1, shuffled.count / 4)))
            let isTest = sources.map { test.contains($0) }
            let bothClasses: Bool = labels.map { y in
                Set(zip(y, isTest).filter { $0.1 }.map(\.0)).count == 2 && Set(zip(y, isTest).filter { !$0.1 }.map(\.0)).count == 2
            } ?? true
            if bothClasses { return HeadSplit(isTest: isTest, basis: .sources, testKeys: test.sorted(by: pythonOrder)) }
            var fallback = byIDs(ids)
            fallback.basis = .idsAfterOneClassSources
            return fallback
        }
        return byIDs(ids)
    }

    static func byIDs(_ ids: [String]) -> HeadSplit {
        var unique = Array(Set(ids)).sorted(by: pythonOrder)
        var rng = PythonRandom(seed: 0)
        rng.shuffle(&unique)
        let test = Set(unique.prefix(max(1, unique.count / 4)))
        return HeadSplit(isTest: ids.map { test.contains($0) }, basis: .ids, testKeys: [String(test.count)])
    }

    /// Python's str ordering: by code point.
    static func pythonOrder(_ a: String, _ b: String) -> Bool { a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) }
}
