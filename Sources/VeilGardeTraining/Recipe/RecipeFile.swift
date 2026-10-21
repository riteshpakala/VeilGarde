//
//  RecipeFile.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A training recipe as a file (recipe.toml), for runs declared without writing Swift:
//
//            id = "weekly-2026-10-21"
//
//            [fusion]
//            mode = "warm"                # warm | scratch
//            add = 80
//            eta = 0.03
//            depth = 5
//            columns = "dino_fusion,cap"  # or "dino_fusion,dino_norm,cap"
//
//            [heads]
//            kinds = ["art", "blur", "human", "preview"]
//
//            [combiner]
//            reals_weight = 3.0
//
//  PIN:  Each table is one model recipe (heads is one per kind); a table that is absent trains
//        nothing; an unknown table or key is refused, never ignored.
//

import Foundation
import VeilGardeCore

public enum RecipeFile {
    static let keys: [String: Set<String>] = [
        "": ["id"],
        "fusion": ["mode", "add", "trees", "eta", "depth", "columns", "new_generator_weight", "preview_weight"],
        "heads": ["kinds", "C", "version"],
        "combiner": ["reals_weight"],
    ]

    public static func load(_ url: URL) throws -> TrainingRecipe {
        try parse(try String(contentsOf: url, encoding: .utf8))
    }

    public static func parse(_ text: String) throws -> TrainingRecipe {
        let document = try TOMLSubset.parse(text)
        for table in document {
            guard let allowed = keys[table.table] else { throw VeilGardeFailure.usage("recipe: unknown table [\(table.table)]") }
            for entry in table.entries where !allowed.contains(entry.key) {
                throw VeilGardeFailure.usage("recipe: [\(table.table.isEmpty ? "top level" : table.table)] has no key \(entry.key)")
            }
        }
        func v(_ table: String, _ key: String) -> TOMLValue? { TOMLSubset.value(document, table, key) }
        func has(_ table: String) -> Bool { document.contains { $0.table == table } }
        guard let id = v("", "id")?.string else { throw VeilGardeFailure.usage("recipe: the top level needs id = \"…\"") }
        var models: [ModelRecipe] = []
        if has("fusion") {
            var f = FusionHead()
            switch v("fusion", "mode")?.string ?? "warm" {
            case "warm": f = f.warmStart(add: v("fusion", "add")?.integer ?? 80, eta: v("fusion", "eta")?.float ?? 0.03)
            case "scratch": f = f.scratch(trees: v("fusion", "trees")?.integer ?? 500, eta: v("fusion", "eta")?.float ?? 0.04)
            case let other: throw VeilGardeFailure.usage("recipe: [fusion] mode is warm or scratch, not \(other)")
            }
            if let d = v("fusion", "depth")?.integer {
                guard (1...12).contains(d) else { throw VeilGardeFailure.usage("recipe: [fusion] depth is 1 to 12, not \(d)") }
                f = f.depth(d)
            }
            if let c = v("fusion", "columns")?.string {
                guard let layout = FusionLayout(rawValue: c.replacingOccurrences(of: " ", with: "")) else {
                    throw VeilGardeFailure.usage("recipe: [fusion] columns is one of \(FusionLayout.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")), not \"\(c)\"")
                }
                f = f.columns(layout)
            }
            if let w = v("fusion", "new_generator_weight")?.float { f = f.newGeneratorWeight(w) }
            if let w = v("fusion", "preview_weight")?.float { f = f.previewWeight(w) }
            models.append(.fusion(f))
        }
        if has("heads") {
            let kinds = v("heads", "kinds")?.strings ?? HeadKind.flywheelCategories.map(\.rawValue)
            for name in kinds {
                guard let kind = HeadKind(rawValue: name) else {
                    throw VeilGardeFailure.usage("recipe: [heads] kind \(name) is not one of \(HeadKind.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                var h = DinoHead(kind)
                if let C = v("heads", "C")?.float { h = h.regularization(C: C) }
                if let version = v("heads", "version")?.string { h = h.version(version) }
                models.append(.head(h))
            }
        }
        if has("combiner") {
            var c = Combiner()
            if let w = v("combiner", "reals_weight")?.float { c = c.realsWeight(w) }
            models.append(.combiner(c))
        }
        return TrainingRecipe(id: id, models: models)
    }
}
