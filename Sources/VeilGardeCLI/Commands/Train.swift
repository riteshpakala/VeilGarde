//
//  Train.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde train`: every model VeilGarde ships, trained into a candidate bundle at
//        <work area>/candidates/<id>/ that `veilgarde route --bundle` runs. `plan` prints what a
//        recipe would do without doing it; `warp`, `calibration`, `fusion`, `heads`,
//        `combiner` and `noiseprint` train one model (warp brings its calibration unless told
//        not to); `all` trains the shipped preset and `run` a recipe.toml.
//  PIN:  The parent bundle is the shipped one unless --parent names another (a candidate, or
//        <work area>/live). The store defaults to <work area>/store/shards; --store names
//        another (any store in the same shard format reads as is). Train in release:
//        VEILGARDE_CONFIG=release scripts/cli.sh train …
//

import ArgumentParser
import Foundation
import VeilGarde

struct TrainingOptions: ParsableArguments {
    @OptionGroup var workArea: WorkAreaOptions
    @Option(help: "The bundle the candidate starts from (default: the shipped bundle; `live` for <work area>/live).") var parent: String?
    @Option(help: "The feature store directory (default: <work area>/store/shards).") var store: String?
    @Option(help: "The candidate's id, its folder under <work area>/candidates (default: <what>-<date>-<time>).") var id: String?
    @Flag(help: "Replace a candidate with the same id.") var replace = false
    @Flag(help: "Print the plan and stop.") var plan = false

    func candidateID(_ what: String) -> String {
        if let id { return id }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(what)-\(f.string(from: Date()))"
    }

    func engine() throws -> TrainingEngine {
        let area = try workArea.resolve()
        let parentURL: URL
        switch parent {
        case nil: parentURL = ShippedBundle.directory
        case "live"?: parentURL = area.root.appendingPathComponent("live", isDirectory: true)
        case let path?: parentURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        let storeURL = store.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        ShippedBundle.registerWeightFolders(workArea: area)
        let engine = TrainingEngine(area: area, parent: parentURL, store: storeURL) { event in if let line = event.line { note(line) } }
        engine.replace = replace
        return engine
    }

    /// Plans, prints the plan (to stdout with --plan, else to stderr) and trains unless --plan.
    func run(_ recipe: TrainingRecipe) throws {
        let engine = try self.engine()
        let plan = try engine.plan(recipe)
        if self.plan {
            print(plan.summary)
            if !plan.refusals.isEmpty { throw VeilGardeFailure.usage("the recipe is refused:\n  " + plan.refusals.joined(separator: "\n  ")) }
            return
        }
        note(plan.summary)
        let outcome = try engine.train(recipe)
        print("candidate \(outcome.candidate.id): \(outcome.candidate.root.path)")
        print(String(format: "  %d artifacts, trained in %.1fs", outcome.candidate.manifest.artifacts.count, outcome.seconds))
        for model in recipe.ordered.map(\.name) { print("  \(model): \(outcome.candidate.root.path)/\(metricsFile(model))") }
        let noiseprint = recipe.models.contains { if case .noiseprint = $0 { return true } else { return false } }
        print("run it:  veilgarde route <image> --bundle \(outcome.candidate.root.path)"
              + (noiseprint ? " --weights-dir \(outcome.candidate.root.path)/noiseprint" : ""))
    }

    func metricsFile(_ model: String) -> String {
        switch model {
        case "warp-tile": return "warp/metrics.json"
        case "sensor-calibration": return "calibration/metrics.json"
        case "fusion-head": return "fusion/metrics.json"
        case "combiner": return "combiner/metrics.json"
        case "noiseprint": return "noiseprint/metrics.json"
        default: return "heads/\(model.dropFirst("head:".count))/metrics.json"
        }
    }
}

func datasetURL(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

struct TrainCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "train", abstract: "Train VeilGarde's models into a candidate bundle: the warp tile model, its calibration, the fusion head, the heads, the combiner, the noiseprint.",
        discussion: "Train in release (VEILGARDE_CONFIG=release scripts/cli.sh train …). A candidate is a full bundle: run it with `veilgarde route <image> --bundle <candidate>`.",
        subcommands: [Plan.self, Warp.self, Calibration.self, Fusion.self, Heads.self, Combine.self, Noiseprint.self, All.self, Run.self])

    struct Plan: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "plan", abstract: "Print what a recipe would train and why, without training (no MLX, no writes).")
        @Option(help: "A recipe.toml.") var recipe: String?
        @Option(help: "The shipped preset over this dataset (final_mixed's folder or a dataset.jsonl).") var preset: String?
        @OptionGroup var options: TrainingOptions

        func run() throws {
            guarded {
                let r: TrainingRecipe
                if let recipe { r = try RecipeFile.load(datasetURL(recipe)) } else if let preset {
                    r = TrainingRecipe.shipped(id: options.candidateID("shipped"), dataset: datasetURL(preset))
                } else { throw VeilGardeFailure.usage("name a --recipe file or a --preset dataset") }
                let plan = try options.engine().plan(r)
                print(plan.summary)
                if !plan.refusals.isEmpty { throw VeilGardeFailure.usage("the recipe is refused:\n  " + plan.refusals.joined(separator: "\n  ")) }
            }
        }
    }

    struct Warp: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "warp", abstract: "Train the warp tile model on a dataset's tiles (and its sensor calibration).")
        @Option(help: "final_mixed's folder (manifest.csv) or a dataset.jsonl.") var dataset: String
        @Option(help: "deployed (optimal_8's shape) or v18.") var shape: String = WarpShape.deployed.rawValue
        @Option(name: .customLong("sample-per-label"), help: "At most this many images of each label (a quick run).") var samplePerLabel: Int?
        @Option(help: "Override the shape's tree count.") var trees: Int?
        @Option(help: "Override the shape's depth.") var depth: Int?
        @Option(help: "Override the shape's learning rate.") var eta: Double?
        @Flag(name: .customLong("no-calibration"), help: "Do not refit the calibration (the sensor lane then falls back to identity).") var noCalibration = false
        @OptionGroup var options: TrainingOptions

        func run() throws {
            guarded {
                guard let s = WarpShape(rawValue: shape) else { throw VeilGardeFailure.usage("--shape is deployed or v18, not \(shape)") }
                var w = WarpTileModel(dataset: datasetURL(dataset)).shape(s)
                if let samplePerLabel { w = w.sample(perLabel: samplePerLabel) }
                if let trees { w = w.trees(trees) }
                if let depth { w = w.depth(depth) }
                if let eta { w = w.eta(eta) }
                let calibrate = !noCalibration
                try options.run(TrainingRecipe(id: options.candidateID("warp")) {
                    w
                    if calibrate { SensorCalibration() }
                })
            }
        }
    }

    struct Calibration: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "calibration", abstract: "Refit the parent's sensor calibration on a dataset's validation images.")
        @Option(help: "final_mixed's folder (manifest.csv) or a dataset.jsonl.") var dataset: String
        @Option(name: .customLong("max-real-fpr"), help: "The real false-positive ceiling the threshold is chosen under.") var maxRealFPR: Double = 0.10
        @Option(help: "The inconclusive band.") var band: Double = 0.04
        @OptionGroup var options: TrainingOptions

        func run() throws {
            guarded {
                try options.run(TrainingRecipe(id: options.candidateID("calibration")) {
                    SensorCalibration(dataset: datasetURL(dataset)).maxRealFPR(maxRealFPR).band(band)
                })
            }
        }
    }

    struct Fusion: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "fusion", abstract: "Train the fusion head on the store: a warm start on the parent's (the flywheel's way) or from scratch.")
        @Option(help: "warm or scratch.") var mode: String = "warm"
        @Option(help: "Trees to add (warm) or to grow (scratch).") var trees: Int?
        @Option(help: "The learning rate.") var eta: Double?
        @Option(name: .customLong("new-generator-weight"), help: "The weight on new-generator rows.") var newGeneratorWeight: Double = 1.0
        @Flag(name: .customLong("allow-mixed-warp"), help: "Train on rows whose warp column came from different warp models.") var allowMixedWarp = false
        @OptionGroup var options: TrainingOptions

        func run() throws {
            guarded {
                var f = FusionHead().newGeneratorWeight(newGeneratorWeight)
                switch mode {
                case "warm": f = f.warmStart(add: trees ?? 80, eta: eta ?? 0.03)
                case "scratch": f = f.scratch(trees: trees ?? 500, eta: eta ?? 0.04)
                default: throw VeilGardeFailure.usage("--mode is warm or scratch, not \(mode)")
                }
                if allowMixedWarp { f = f.allowMixedWarp() }
                try options.run(TrainingRecipe(id: options.candidateID("fusion")) { f })
            }
        }
    }

    struct Heads: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "heads", abstract: "Train specialist heads on the store's dino_norm column (each head's recipe, admission measured).")
        @Option(help: "Comma-separated kinds (default: art,blur,human,cgi).") var kinds: String = HeadKind.flywheelCategories.map(\.rawValue).joined(separator: ",")
        @OptionGroup var options: TrainingOptions

        func run() throws {
            guarded {
                let parsed = try kinds.split(separator: ",").map { name -> HeadKind in
                    guard let kind = HeadKind(rawValue: String(name)) else {
                        throw VeilGardeFailure.usage("unknown head \(name); heads are \(HeadKind.allCases.map(\.rawValue).joined(separator: ", "))")
                    }
                    return kind
                }
                try options.run(TrainingRecipe(id: options.candidateID("heads")) { for kind in parsed { DinoHead(kind) } })
            }
        }
    }

    struct Combine: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "combiner", abstract: "Fit the stack combiner on the store's capture-absent rows under the parent's base and heads.")
        @Option(name: .customLong("reals-weight"), help: "The weight on real rows.") var realsWeight: Double = 3
        @OptionGroup var options: TrainingOptions

        func run() throws {
            guarded { try options.run(TrainingRecipe(id: options.candidateID("combiner")) { Combiner().realsWeight(realsWeight) }) }
        }
    }

    struct Noiseprint: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "noiseprint", abstract: "Train the noiseprint CNN from camera originals against everything that is not a capture (GPU).",
            discussion: "The v202 recipe on the T9's folders. The net is frozen in the flywheel; the candidate carries it for measurement (route with --weights-dir <candidate>/noiseprint).")
        @Option(help: "Epochs.") var epochs: Int = 6
        @Option(help: "The batch size.") var batch: Int = 256
        @Option(name: .customLong("per-family"), help: "Images per negative family (three quarters train).") var perFamily: Int = 120
        @Option(help: "The seed for the weights and the epoch order.") var seed: UInt64 = 0
        @Flag(name: .customLong("no-patch-cache"), help: "Cut the patches again instead of reading the work area's cache.") var noPatchCache = false
        @OptionGroup var options: TrainingOptions

        func run() throws {
            guarded {
                let n = NoiseprintModel().epochs(epochs).batch(batch).perFamily(perFamily).seed(seed).cachePatches(!noPatchCache)
                try options.run(TrainingRecipe(id: options.candidateID("noiseprint")) { n })
            }
        }
    }

    struct All: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "all", abstract: "Train the shipped preset: every model VeilGarde ships that a dataset and the store reproduce.")
        @Option(help: "final_mixed's folder (manifest.csv) or a dataset.jsonl, for the warp tile model.") var dataset: String
        @OptionGroup var options: TrainingOptions

        func run() throws {
            guarded { try options.run(TrainingRecipe.shipped(id: options.candidateID("shipped"), dataset: datasetURL(dataset))) }
        }
    }

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "run", abstract: "Train a recipe.toml.")
        @Argument(help: "The recipe file.") var recipe: String
        @OptionGroup var options: TrainingOptions

        func run() throws {
            guarded { try options.run(try RecipeFile.load(datasetURL(recipe))) }
        }
    }
}
