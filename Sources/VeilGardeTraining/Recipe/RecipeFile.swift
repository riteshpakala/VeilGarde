//
//  RecipeFile.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A training recipe as a file (recipe.toml), for runs declared without writing Swift:
//
//            id = "weekly-2026-10-19"
//
//            [warp]                       # the warp tile model (and, by default, its calibration)
//            dataset = "~/datasets/final_mixed"
//            shape = "deployed"           # deployed | v18
//            sample_per_label = 200       # optional: a quick run
//
//            [calibration]
//            max_real_fpr = 0.10
//            band = 0.04
//
//            [fusion]
//            mode = "warm"                # warm | scratch
//            add = 80
//            eta = 0.03
//
//            [heads]
//            kinds = ["art", "blur", "human", "cgi", "preview"]
//
//            [combiner]
//            reals_weight = 3.0
//
//            [noiseprint]                 # the noiseprint CNN, from images (GPU, about an hour)
//            epochs = 6
//            per_family = 120
//
//  PIN:  Each table is one model recipe (heads is one per kind); a table that is absent trains
//        nothing; an unknown table or key is refused, never ignored. [calibration] without
//        [warp] needs its own `dataset`.
//

import Foundation
import VeilGardeCore

public enum RecipeFile {
    static let keys: [String: Set<String>] = [
        "": ["id"],
        "warp": ["dataset", "shape", "sample_per_label", "sample_seed", "trees", "depth", "eta", "seed"],
        "calibration": ["dataset", "max_real_fpr", "band"],
        "fusion": ["mode", "add", "trees", "eta", "new_generator_weight", "preview_weight", "allow_mixed_warp"],
        "heads": ["kinds", "C", "version"],
        "combiner": ["reals_weight"],
        "noiseprint": ["epochs", "batch", "learning_rate", "per_family", "seed", "cache_patches"],
    ]

    public static func load(_ url: URL) throws -> TrainingRecipe {
        try parse(try String(contentsOf: url, encoding: .utf8), relativeTo: url.deletingLastPathComponent())
    }

    public static func parse(_ text: String, relativeTo base: URL? = nil) throws -> TrainingRecipe {
        let document = try TOMLSubset.parse(text)
        for table in document {
            guard let allowed = keys[table.table] else { throw VeilGardeFailure.usage("recipe: unknown table [\(table.table)]") }
            for entry in table.entries where !allowed.contains(entry.key) {
                throw VeilGardeFailure.usage("recipe: [\(table.table.isEmpty ? "top level" : table.table)] has no key \(entry.key)")
            }
        }
        func v(_ table: String, _ key: String) -> TOMLValue? { TOMLSubset.value(document, table, key) }
        func has(_ table: String) -> Bool { document.contains { $0.table == table } }
        func path(_ s: String) -> URL {
            let expanded = (s as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
            return (base ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).appendingPathComponent(expanded)
        }
        guard let id = v("", "id")?.string else { throw VeilGardeFailure.usage("recipe: the top level needs id = \"…\"") }
        var models: [ModelRecipe] = []
        if has("warp") {
            guard let dataset = v("warp", "dataset")?.string else { throw VeilGardeFailure.usage("recipe: [warp] needs dataset") }
            var w = WarpTileModel(dataset: path(dataset))
            if let s = v("warp", "shape")?.string {
                guard let shape = WarpShape(rawValue: s) else { throw VeilGardeFailure.usage("recipe: [warp] shape is deployed or v18, not \(s)") }
                w = w.shape(shape)
            }
            if let n = v("warp", "sample_per_label")?.integer { w = w.sample(perLabel: n, seed: UInt64(v("warp", "sample_seed")?.integer ?? 0)) }
            if let n = v("warp", "trees")?.integer { w = w.trees(n) }
            if let n = v("warp", "depth")?.integer { w = w.depth(n) }
            if let e = v("warp", "eta")?.float { w = w.eta(e) }
            if let s = v("warp", "seed")?.integer { w = w.seed(UInt64(s)) }
            models.append(.warpTile(w))
        }
        if has("calibration") {
            var c = SensorCalibration(dataset: v("calibration", "dataset")?.string.map(path))
            if let f = v("calibration", "max_real_fpr")?.float { c = c.maxRealFPR(f) }
            if let b = v("calibration", "band")?.float { c = c.band(b) }
            models.append(.calibration(c))
        }
        if has("fusion") {
            var f = FusionHead()
            switch v("fusion", "mode")?.string ?? "warm" {
            case "warm": f = f.warmStart(add: v("fusion", "add")?.integer ?? 80, eta: v("fusion", "eta")?.float ?? 0.03)
            case "scratch": f = f.scratch(trees: v("fusion", "trees")?.integer ?? 500, eta: v("fusion", "eta")?.float ?? 0.04)
            case let other: throw VeilGardeFailure.usage("recipe: [fusion] mode is warm or scratch, not \(other)")
            }
            if let w = v("fusion", "new_generator_weight")?.float { f = f.newGeneratorWeight(w) }
            if let w = v("fusion", "preview_weight")?.float { f = f.previewWeight(w) }
            if v("fusion", "allow_mixed_warp")?.bool == true { f = f.allowMixedWarp() }
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
        if has("noiseprint") {
            var n = NoiseprintModel()
            if let e = v("noiseprint", "epochs")?.integer { n = n.epochs(e) }
            if let b = v("noiseprint", "batch")?.integer { n = n.batch(b) }
            if let r = v("noiseprint", "learning_rate")?.float { n = n.learningRate(r) }
            if let f = v("noiseprint", "per_family")?.integer { n = n.perFamily(f) }
            if let s = v("noiseprint", "seed")?.integer { n = n.seed(UInt64(s)) }
            if let c = v("noiseprint", "cache_patches")?.bool { n = n.cachePatches(c) }
            models.append(.noiseprint(n))
        }
        return TrainingRecipe(id: id, models: models)
    }
}
