//
//  Research.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde research`: measurements of the detector, part by part. `census` runs the full
//        detector over images (the battery's, a final_mixed sample, or any given) and counts how
//        often each mechanism and stack row runs, how often it decides the call, and how often the
//        stack and the semantic chain move it; `compare` judges one census against another
//        (ResearchCompare.swift).
//  PIN:  census is one MLX workload, one image at a time. It writes
//        <work area>/research/census-<stamp>.json and prints a table, and names the bundle it ran
//        and its hashes. A census written before 2026-10-21 also carries the warp lens's and the
//        camera-sensor's fields; they read as absent now.
//

import ArgumentParser
import Foundation
import VeilGarde

struct ResearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "research", abstract: "Measure the detector part by part: the mechanism census, and one census judged against another.",
        subcommands: [Census.self, Compare.self])

    static func output(_ area: WorkArea, _ what: String) throws -> URL {
        let folder = area.root.appendingPathComponent("research", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(what)-\(FlywheelArea.stamp()).json")
    }

    struct Census: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "census", abstract: "Run the full detector over images and count how often each mechanism runs and decides the call.",
            discussion: "With no images it takes the battery's (every group) and a final_mixed sample. One MLX workload, one image at a time.")
        @Argument(help: "Images, folders (searched recursively), or text files of image paths (one per line).") var images: [String] = []
        @Option(help: "The label of the images named as arguments: real or generated.") var label: String?
        @Flag(help: "Add the battery's images (every group of the work area's spec).") var battery = false
        @Option(help: "Add this many final_mixed images, half real and half generated, every k-th by name.") var sample = 0
        @Option(name: .customLong("final-mixed"), help: "The final_mixed folder (default: final_mixed under VEILGARDE_DATASETS, else the work area's datasets/).") var finalMixed: String?
        @Option(help: "Write the census here too (`-` for stdout).") var json: String?
        @OptionGroup var route: RouteOptions
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
                let config = try route.config()
                var census = MechanismCensus()
                census.bundle = config.bundle.directory.path
                census.provenance = config.bundle.provenance
                census.weightsDir = route.weightsDir
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
        /// The base expert's own call (the first stack row).
        var baseCall: String? = nil
    }

    var date = Date()
    /// What ran: the bundle, its artifacts' hashes, and the weights.
    var bundle: String? = nil
    var provenance: [String: String]? = nil
    var weightsDir: String? = nil
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
    /// By label ("unlabelled" when unknown), then the routed call.
    var finalCalls: [String: [String: Int]]? = nil

    mutating func add(_ path: String, label: String?, _ r: InferenceResult, domain: String) {
        let cap = r.captureSignature.map { $0.valid ? ($0.present ? "present" : "absent") : "invalid" } ?? "none"
        let d = r.routeDiagnostics
        let stack = r.specialists ?? []
        var row = Row(path: path, label: label, route: domain, capture: cap, baseP: d?.baseP, preSemanticP: d?.preSemanticP, p: r.p,
                      call: r.prediction, preSemanticCall: d?.preSemanticPrediction, shown: stack.map(\.name),
                      decisive: stack.filter { $0.weight >= 1 }.map(\.name), semanticTriggered: d?.semanticTriggered ?? false,
                      semanticDecisive: d?.semanticDecisive ?? false, previewTriggered: d?.previewTriggered ?? false, previewDecisive: d?.previewDecisive ?? false)
        row.baseCall = stack.first?.verdict
        rows.append(row)
        finalCalls = Self.counted(finalCalls, label ?? "unlabelled", row.call)
        routes[domain, default: 0] += 1
        capture[cap, default: 0] += 1
        for name in Set(row.shown) { shown[name, default: 0] += 1 }
        for name in Set(row.decisive) { decisive[name, default: [:]][label ?? "unlabelled", default: 0] += 1 }
        if cap != "present", let base = d?.baseP, let pre = d?.preSemanticPrediction, (base > 0.5 ? "generated" : "real") != pre { stackMovedCall += 1 }
        if let pre = d?.preSemanticPrediction, pre != r.prediction { semanticMovedCall += 1 }
        if let label {
            labelled[label, default: 0] += 1
            if r.prediction == label { correct[label, default: 0] += 1 }
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
        if let bundle { lines.append("bundle \(bundle)") }
        lines.append("  stack row                shown  full weight (by label)")
        for (name, n) in shown.sorted(by: { $0.value > $1.value }) {
            let by = (decisive[name] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            let label = name.count >= 24 ? name : name + String(repeating: " ", count: 24 - name.count)
            lines.append("  " + label + String(format: " %5d  ", n) + (by.isEmpty ? "—" : by))
        }
        lines.append("the stack moved the base's call on \(stackMovedCall) capture-absent images; the semantic chain moved the call on \(semanticMovedCall)")
        lines.append("correct: " + labelled.sorted { $0.key < $1.key }.map { "\($0.key) \(correct[$0.key] ?? 0) of \($0.value)" }.joined(separator: ", "))
        if let table = finalCalls {
            lines.append("routed calls: " + table.sorted { $0.key < $1.key }.map { label, calls in
                "\(label) " + ["real", "inconclusive", "generated"].map { "\($0) \(calls[$0] ?? 0)" }.joined(separator: " / ")
            }.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}
