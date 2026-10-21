//
//  Research.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde research`: measurements that ask what the system could do without. `prune`
//        runs the pruning study (PruningStudy) on the work area's tile cache and store against the
//        shipped bundle; `core` refits the warp tile model on feature subsets (CoreStudy,
//        ResearchCore.swift); `census` runs the full detector over images (the battery's, a final_mixed
//        sample, or any given) and counts how often each mechanism and stack row runs, how often it
//        decides the call, and how often the stack and the semantic chain move it.
//  PIN:  prune is CPU work on cached tiles and stored features; census is one MLX workload, one
//        image at a time. Each writes <work area>/research/<what>-<stamp>.json and prints a table.
//        A census names the bundle and the base expert it ran, and per image the sensor call and
//        the warp lens's own score beside the routed verdict (fields older censuses lack).
//

import ArgumentParser
import Foundation
import VeilGarde

struct ResearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "research", abstract: "Measure what the system could do without: the pruning study and the mechanism census.",
        subcommands: [Prune.self, Core.self, Redundancy.self, Condensed.self, Census.self, Compare.self])

    static func output(_ area: WorkArea, _ what: String) throws -> URL {
        let folder = area.root.appendingPathComponent("research", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(what)-\(FlywheelArea.stamp()).json")
    }

    struct Prune: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "prune", abstract: "Refit and re-score the warp model, the fusion head and the stack with parts taken out, on held-out data.",
            discussion: "The rules are fixed in the report (ledger decision-68). The warp part refits the deployed shape about 30 times on the tile cache; the fusion part refits the scratch recipe 8 times on the store.")
        @Option(help: "The parts to study: warp, fusion, stack, comma separated.") var parts = "warp,fusion,stack"
        @Option(help: "Bootstrap resamples per comparison.") var resamples = 1000
        @Option(help: "The warp tile cache (default: <work area>/store/tiles/final_mixed).") var tiles: String?
        @Option(help: "The feature store (default: <work area>/store/shards).") var store: String?
        @Flag(name: .customLong("no-single-features"), help: "Skip the 19 single-feature refits.") var noSingleFeatures = false
        @Option(help: "Fusion trees for the scratch refits.") var fusionTrees = 500
        @Option(help: "Write the report here too (`-` for stdout).") var json: String?
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let area = try workArea.resolve()
                var settings = PruningSettings()
                settings.resamples = resamples
                settings.singleFeatures = !noSingleFeatures
                settings.fusionTrees = fusionTrees
                settings.fusionStages = settings.fusionStages.filter { $0 < fusionTrees }
                let chosen = try Set(parts.split(separator: ",").map { name -> PruningPart in
                    guard let p = PruningPart(rawValue: name.trimmingCharacters(in: .whitespaces)) else { throw VeilGardeFailure.usage("--parts names warp, fusion and stack, not \(name)") }
                    return p
                })
                let inputs = PruningStudy.Inputs(tiles: tiles.map(datasetURL) ?? area.tiles.appendingPathComponent("final_mixed", isDirectory: true),
                                                 store: store.map(datasetURL) ?? area.shards, bundle: try ShippedBundle.verified())
                let report = try PruningStudy.run(inputs, settings: settings, parts: chosen, note: note)
                let file = try ResearchCommand.output(area, "prune")
                try JSONCoding.write(report, to: file)
                if let json { try emitJSON(try JSONCoding.prettyEncoder().encode(report), to: json) }
                print(Self.table(report))
                note("report: \(file.path)")
            }
        }

        static func table(_ r: PruningReport) -> String {
            var lines: [String] = []
            func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
            func section(_ title: String, _ rows: [PruningRow]) {
                guard !rows.isEmpty else { return }
                lines.append(title)
                for row in rows {
                    let p = row.primary
                    var line = "  " + pad(row.name, 30) + String(format: " %+.4f [%+.4f, %+.4f]", p.delta, p.low, p.high)
                    if let s = row.secondary { line += String(format: "  vote %+.4f", s.delta) }
                    line += "  moved \(p.changedCalls)  \(row.verdict)"
                    lines.append(line)
                }
            }
            if let w = r.warp {
                lines.append(String(format: "warp: refit deployed shape, test weighted AUC %.4f, vote AUC %.4f (%d images); shipped %.4f / %.4f on its own corpus",
                                    w.reference.imageWeightedAUC, w.reference.imageMajorityAUC, w.testImages, w.shipped.imageWeightedAUC, w.shipped.imageMajorityAUC))
                section(" the control: another seed", w.seeds)
                section(" trees", w.trees); section(" depth", w.depths); section(" a group shuffled", w.permuted); section(" a group refit out", w.groupsDropped)
                section(" groups refit out together", w.groupsTogether)
                section(" a feature refit out", w.featuresDropped); section(" together", w.droppedTogether.map { [$0] } ?? []); section(" other image scores", w.scores)
                section(" shipped, trees", w.shippedTrees); section(" shipped, a group shuffled", w.shippedPermuted)
                let c = w.calibration
                lines.append(String(format: " calibration: the call is a raw tile-vote cut on %d of %d images (real ≤ %.4f, generated ≥ %.4f)", c.agreeing, c.images, c.rawReal, c.rawGenerated))
            }
            if let f = r.fusion {
                lines.append(String(format: "fusion: scratch recipe on all inputs, AUC %.4f on %d held-out rows; shipped %.4f (reliance)", f.referenceAUC, f.testRows, f.shippedAUC))
                section(" the control: another seed", f.seeds)
                section(" trees", f.trees); section(" depth", f.depths); section(" inputs", f.inputs); section(" inputs together", f.inputsTogether)
                section(" shipped, trees", f.shippedTrees); section(" shipped, an input shuffled", f.shippedPermuted)
            }
            if let s = r.stack {
                lines.append(String(format: "stack: %d capture-absent rows, AUC %.4f, real FPR %.3f, generated recall %.3f; live: %@",
                                    s.rows, s.shippedAUC, s.shippedRealFPR, s.shippedGeneratedRecall, s.active.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
                section(" a term or head out", s.variants)
            }
            return lines.joined(separator: "\n")
        }
    }

    struct Census: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "census", abstract: "Run the full detector over images and count how often each mechanism runs and decides the call.",
            discussion: "With no images it takes the battery's (every group) and a final_mixed sample. One MLX workload, one image at a time.")
        @Argument(help: "Images, folders (searched recursively), or text files of image paths (one per line).") var images: [String] = []
        @Option(help: "The label of the images named as arguments: real or generated.") var label: String?
        @Option(help: "A bundle directory to detect with instead of the shipped one (live, or a candidate).") var bundle: String?
        @OptionGroup var expert: BaseExpertOptions
        @Flag(help: "Add the battery's images (every group of the work area's spec).") var battery = false
        @Option(help: "Add this many final_mixed images, half real and half generated, every k-th by name.") var sample = 0
        @Option(name: .customLong("final-mixed"), help: "The final_mixed folder (default: final_mixed under VEILGARDE_DATASETS, else the work area's datasets/).") var finalMixed: String?
        @Option(help: "Write the census here too (`-` for stdout).") var json: String?
        @OptionGroup var route: DetectionOptions
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let area = try workArea.resolve()
                if let label, !["real", "generated"].contains(label) { throw VeilGardeFailure.usage("--label is real or generated, not \(label)") }
                var items: [(path: String, label: String?)] = []
                for input in images { items += try imageInputs(input).map { ($0.path, label) } }
                let defaults = images.isEmpty && !battery && sample == 0
                if battery || defaults {
                    let fly = FlywheelArea(area)
                    let spec = try BatterySpec.load(fly.batterySpec)
                    for group in try spec.resolve(gate: .full, vars: spec.resolvedVars(images: fly.batteryImages)) {
                        items += group.files.map { ($0, group.want) }
                    }
                }
                let count = defaults ? 200 : sample
                if count > 0 {
                    guard let finalMixed = finalMixed.map(datasetURL) ?? WorkArea.datasets().map({ $0.appendingPathComponent("final_mixed") }) else {
                        throw VeilGardeFailure.usage("no final_mixed: pass --final-mixed or set VEILGARDE_DATASETS")
                    }
                    for label in ["real", "generated"] {
                        let folder = finalMixed.appendingPathComponent(label)
                        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                            .filter { !$0.hasPrefix(".") && ["jpg", "jpeg", "png", "webp", "heic"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }.sorted()
                        let k = max(1, names.count / max(1, count / 2))
                        items += stride(from: 0, to: names.count, by: k).prefix(count / 2).map { (folder.appendingPathComponent(names[$0]).path, label) }
                    }
                }
                guard !items.isEmpty else { throw VeilGardeFailure.usage("no images: name some, or pass --battery or --sample") }
                var config = try bundle.map { try route.config(bundle: try DetectorBundle.load(datasetURL($0))) } ?? route.config()
                config.baseExpert = try expert.resolve()
                var census = MechanismCensus()
                census.bundle = config.bundle.directory.path
                census.provenance = config.bundle.provenance
                census.baseExpert = config.baseExpert.rawValue
                census.warpRule = config.decision
                census.weightsDir = route.weightsDir
                census.modelOverride = route.model
                census.dinoVariant = config.dinoVariant.rawValue
                census.coreVersion = VeilGardeVersion.string
                for (k, item) in items.enumerated() {
                    defer { LensRuntime.releaseMemory() }
                    do {
                        let cg = try loadImage(item.path)
                        let routed = try Detector.shared.detect(cgImage: cg, config: config)
                        census.add(item.path, label: item.label, routed.result, domain: routed.domain.rawValue)
                    } catch {
                        census.errors.append("\(item.path): \(error)")
                    }
                    if (k + 1) % 25 == 0 { note("census: \(k + 1) of \(items.count) images") }
                }
                let file = try ResearchCommand.output(area, "census")
                try JSONCoding.write(census, to: file)
                if let json { try emitJSON(try JSONCoding.prettyEncoder().encode(census), to: json) }
                print(census.table)
                note("census: \(file.path)")
            }
        }
    }
}

/// How often each part of the router ran on a set of images, and how often it decided.
struct MechanismCensus: Codable {
    struct Row: Codable {
        var path: String
        var label: String?
        var route: String
        var capture: String
        var baseP: Float?
        var preSemanticP: Float?
        var p: Float
        var call: String
        var preSemanticCall: String?
        var shown: [String]
        var decisive: [String]
        var semanticTriggered: Bool
        var semanticDecisive: Bool
        var previewTriggered: Bool
        var previewDecisive: Bool
        /// The camera-sensor call and its vote (the majority route), nil off the camera route.
        var sensorP: Float? = nil
        var sensorCall: String? = nil
        /// The warp lens's own weighted score and its call at the warp rule, whatever the base expert.
        var warpP: Float? = nil
        var warpCall: String? = nil
        /// The base expert's own call (the first stack row).
        var baseCall: String? = nil
    }

    var date = Date()
    /// What ran: the bundle, its artifacts' hashes, the base expert and the overrides.
    var bundle: String? = nil
    var provenance: [String: String]? = nil
    var baseExpert: String? = nil
    var warpRule: DecisionRule? = nil
    var weightsDir: String? = nil
    var modelOverride: String? = nil
    var dinoVariant: String? = nil
    var coreVersion: String? = nil
    var rows: [Row] = []
    var errors: [String] = []
    var routes: [String: Int] = [:]
    var capture: [String: Int] = [:]
    /// Stack rows by name: how many images showed each.
    var shown: [String: Int] = [:]
    /// Stack rows at full weight (the part that decided or moved the call), by name, then by label.
    var decisive: [String: [String: Int]] = [:]
    /// Capture-absent images whose pre-semantic call differs from the fusion base's call at 0.5.
    var stackMovedCall = 0
    /// Images whose final call differs from the pre-semantic one.
    var semanticMovedCall = 0
    /// The final call against the label, where the label is known.
    var correct: [String: Int] = [:]
    var labelled: [String: Int] = [:]
    /// By label ("unlabelled" when unknown), then call: the sensor's, the routed verdict's, the warp lens's own.
    var sensorCalls: [String: [String: Int]]? = nil
    var finalCalls: [String: [String: Int]]? = nil
    var warpCalls: [String: [String: Int]]? = nil
    /// The warp lens's own call against the label.
    var warpCorrect: [String: Int]? = nil

    mutating func add(_ path: String, label: String?, _ r: InferenceResult, domain: String) {
        let cap = r.captureSignature.map { $0.valid ? ($0.present ? "present" : "absent") : "invalid" } ?? "none"
        let d = r.routeDiagnostics
        let stack = r.specialists ?? []
        var row = Row(path: path, label: label, route: domain, capture: cap, baseP: d?.warpP, preSemanticP: d?.preSemanticP, p: r.weightedScore,
                      call: r.weightedPrediction, preSemanticCall: d?.preSemanticPrediction, shown: stack.map(\.name),
                      decisive: stack.filter { $0.weight >= 1 }.map(\.name), semanticTriggered: d?.semanticTriggered ?? false,
                      semanticDecisive: d?.semanticDecisive ?? false, previewTriggered: d?.previewTriggered ?? false, previewDecisive: d?.previewDecisive ?? false)
        row.sensorP = r.sensorRawProbability
        row.sensorCall = r.sensorPrediction
        row.warpP = r.warpWeightedScore
        row.warpCall = r.warpWeightedScore.map { (warpRule ?? .warpWeighted).label($0) }
        row.baseCall = stack.first?.verdict
        rows.append(row)
        let key = label ?? "unlabelled"
        if let s = row.sensorCall { sensorCalls = Self.counted(sensorCalls, key, s) }
        finalCalls = Self.counted(finalCalls, key, row.call)
        if let w = row.warpCall {
            warpCalls = Self.counted(warpCalls, key, w)
            if let label { warpCorrect = (warpCorrect ?? [:]).merging([label: w == label ? 1 : 0], uniquingKeysWith: +) }
        }
        routes[domain, default: 0] += 1
        capture[cap, default: 0] += 1
        for name in Set(row.shown) { shown[name, default: 0] += 1 }
        for name in Set(row.decisive) { decisive[name, default: [:]][label ?? "unlabelled", default: 0] += 1 }
        if cap != "present", let base = d?.warpP, let pre = d?.preSemanticPrediction, (base > 0.5 ? "generated" : "real") != pre { stackMovedCall += 1 }
        if let pre = d?.preSemanticPrediction, pre != r.weightedPrediction { semanticMovedCall += 1 }
        if let label {
            labelled[label, default: 0] += 1
            if r.weightedPrediction == label { correct[label, default: 0] += 1 }
        }
    }

    static func counted(_ table: [String: [String: Int]]?, _ label: String, _ call: String) -> [String: [String: Int]] {
        var t = table ?? [:]
        t[label, default: [:]][call, default: 0] += 1
        return t
    }

    var table: String {
        var lines = ["census: \(rows.count) images (\(errors.count) errors); routes " + routes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                     + "; capture " + capture.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")]
        if let bundle { lines.append("bundle \(bundle), base \(baseExpert ?? "fusion")" + (modelOverride.map { ", base warp model \($0)" } ?? "")) }
        lines.append("  stack row                shown  full weight (by label)")
        for (name, n) in shown.sorted(by: { $0.value > $1.value }) {
            let by = (decisive[name] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            let label = name.count >= 24 ? name : name + String(repeating: " ", count: 24 - name.count)
            lines.append("  " + label + String(format: " %5d  ", n) + (by.isEmpty ? "—" : by))
        }
        lines.append("the stack moved the base's call on \(stackMovedCall) capture-absent images; the semantic chain moved the call on \(semanticMovedCall)")
        lines.append("correct: " + labelled.sorted { $0.key < $1.key }.map { "\($0.key) \(correct[$0.key] ?? 0) of \($0.value)" }.joined(separator: ", "))
        if let warpCorrect {
            lines.append("the warp lens's own call correct: " + labelled.sorted { $0.key < $1.key }.map { "\($0.key) \(warpCorrect[$0.key] ?? 0) of \($0.value)" }.joined(separator: ", "))
        }
        for (title, table) in [("sensor calls", sensorCalls), ("routed calls", finalCalls)] {
            guard let table else { continue }
            lines.append("\(title): " + table.sorted { $0.key < $1.key }.map { label, calls in
                "\(label) " + ["real", "inconclusive", "generated"].map { "\($0) \(calls[$0] ?? 0)" }.joined(separator: " / ")
            }.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}
