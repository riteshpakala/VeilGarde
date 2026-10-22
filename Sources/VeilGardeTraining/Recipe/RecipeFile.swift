//
//  RecipeFile.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A training recipe as a file (recipe.toml), for runs declared without writing Swift:
//
//            id = "weekly-2026-10-21"
//
//            [camera]
//            mode = "warm"                # warm | scratch
//            add = 80
//            eta = 0.03
//            depth = 5
//
//            [heads]
//            kinds = ["art", "blur", "human", "preview"]
//
//            [combiner]
//            reals_weight = 3.0
//
//  PIN:  Each table is one trainable member (heads is one per kind); a table that is absent trains
//        nothing; an unknown table or key is refused, never ignored.
//

import Foundation
import VeilGardeCore

public enum RecipeFile {
    static let keys: [String: Set<String>] = [
        "": ["id"],
        "camera": ["mode", "add", "trees", "eta", "depth", "new_generator_weight", "preview_weight"],
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
        var members: [AnyTrainable] = []
        if has("camera") {
            var c = CameraHead()
            switch v("camera", "mode")?.string ?? "warm" {
            case "warm": c = c.warmStart(add: v("camera", "add")?.integer ?? 80, eta: v("camera", "eta")?.float ?? 0.03)
            case "scratch": c = c.scratch(trees: v("camera", "trees")?.integer ?? 500, eta: v("camera", "eta")?.float ?? 0.04)
            case let other: throw VeilGardeFailure.usage("recipe: [camera] mode is warm or scratch, not \(other)")
            }
            if let d = v("camera", "depth")?.integer {
                guard (1...12).contains(d) else { throw VeilGardeFailure.usage("recipe: [camera] depth is 1 to 12, not \(d)") }
                c = c.depth(d)
            }
            if let w = v("camera", "new_generator_weight")?.float { c = c.newGeneratorWeight(w) }
            if let w = v("camera", "preview_weight")?.float { c = c.previewWeight(w) }
            members.append(AnyTrainable(c))
        }
        if has("heads") {
            let kinds = v("heads", "kinds")?.strings ?? HeadKind.flywheelCategories.map(\.rawValue)
            for name in kinds {
                guard let kind = HeadKind(rawValue: name) else {
                    throw VeilGardeFailure.usage("recipe: [heads] kind \(name) is not one of \(HeadKind.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                var h = SpecialistHead(kind)
                if let C = v("heads", "C")?.float { h = h.regularization(C: C) }
                if let version = v("heads", "version")?.string { h = h.version(version) }
                members.append(AnyTrainable(h))
            }
        }
        if has("combiner") {
            var c = Combiner()
            if let w = v("combiner", "reals_weight")?.float { c = c.realsWeight(w) }
            members.append(AnyTrainable(c))
        }
        return TrainingRecipe(id: id, members: members)
    }
}
