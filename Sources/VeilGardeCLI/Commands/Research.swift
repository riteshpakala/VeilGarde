//
//  Research.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde research`: measurements of the detector, part by part. `census` runs the full
//        detector over images (the battery's, a final_mixed sample, or any given) and records, for
//        every image, each stack member's P(AI) and verdict and what each revision did, and counts
//        how often each member calls each label, how often each revision acts, and how often the
//        combiner and the later revisions move the call; `compare` judges one census against
//        another (ResearchCompare.swift).
//  PIN:  census is one MLX workload, one image at a time. It writes
//        <work area>/research/census-<stamp>.json and prints a table, and names the bundle it ran
//        and its hashes. Rows keep path, label and call, which compare joins on.
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
            commandName: "census", abstract: "Run the full detector over images and count what every member called and what every revision did.",
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
                        census.add(item.path, label: item.label, try Detector.detect(cgImage: cg, config: config))
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

/// What every member called and every revision did on a set of images.
struct MechanismCensus: Codable {
    struct Row: Codable {
        var path: String
        var label: String?
        var p: Float
        var call: String
        /// The capture member's verdict: real (present), absent or invalid.
        var capture: String
        /// The member the combiner anchored on.
        var anchor: String?
        /// Each member's P(AI), for the members that score.
        var members: [String: Float]
        /// Each member's verdict.
        var memberCalls: [String: String]
        /// Whether each revision changed the verdict.
        var revisions: [String: Bool]
        /// The verdict the combiner set, before the later revisions.
        var combinerCall: String?
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
    var capture: [String: Int] = [:]
    var anchors: [String: Int] = [:]
    /// By member, then the member's verdict, how many images.
    var memberCalls: [String: [String: Int]] = [:]
    /// By revision, then label ("unlabelled" when unknown), how many images it changed.
    var revisionsApplied: [String: [String: Int]] = [:]
    /// Capture-absent images whose combined call differs from the anchor's own call at 0.5.
    var combinerMovedCall = 0
    /// Images whose final call differs from the combiner's.
    var revisionsMovedCall = 0
    /// The final call against the label, where the label is known.
    var correct: [String: Int] = [:]
    var labelled: [String: Int] = [:]
    /// By label ("unlabelled" when unknown), then the call.
    var finalCalls: [String: [String: Int]] = [:]

    mutating func add(_ path: String, label: String?, _ r: InferenceResult) {
        let combiner = r.revisions.revision("combiner")
        let row = Row(path: path, label: label, p: r.p, call: r.prediction, capture: r.stack.member("capture")?.verdict ?? "none",
                      anchor: combiner?.text("anchor"),
                      members: Dictionary(r.stack.compactMap { m in m.p.map { (m.name, $0) } }, uniquingKeysWith: { a, _ in a }),
                      memberCalls: Dictionary(r.stack.map { ($0.name, $0.verdict) }, uniquingKeysWith: { a, _ in a }),
                      revisions: Dictionary(r.revisions.map { ($0.name, $0.applied) }, uniquingKeysWith: { a, _ in a }),
                      combinerCall: combiner?.prediction)
        rows.append(row)
        finalCalls[label ?? "unlabelled", default: [:]][row.call, default: 0] += 1
        capture[row.capture, default: 0] += 1
        if let a = row.anchor { anchors[a, default: 0] += 1 }
        for (name, call) in row.memberCalls { memberCalls[name, default: [:]][call, default: 0] += 1 }
        for (name, applied) in row.revisions where applied { revisionsApplied[name, default: [:]][label ?? "unlabelled", default: 0] += 1 }
        if row.capture != "real", let a = row.anchor, let ap = row.members[a], let c = row.combinerCall, (ap > 0.5 ? "generated" : "real") != c { combinerMovedCall += 1 }
        if let c = row.combinerCall, c != row.call { revisionsMovedCall += 1 }
        if let label {
            labelled[label, default: 0] += 1
            if row.call == label { correct[label, default: 0] += 1 }
        }
    }

    var table: String {
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
        var lines = ["census: \(rows.count) images (\(errors.count) errors); capture " + capture.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                     + "; anchor " + anchors.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")]
        if let bundle { lines.append("bundle \(bundle)") }
        lines.append("  member            calls")
        for (name, calls) in memberCalls.sorted(by: { $0.key < $1.key }) {
            lines.append("  " + pad(name, 18) + calls.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        lines.append("  revision          applied (by label)")
        for name in Set(rows.flatMap { $0.revisions.keys }).sorted() {
            let by = (revisionsApplied[name] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            lines.append("  " + pad(name, 18) + (by.isEmpty ? "—" : by))
        }
        lines.append("the combiner moved the anchor's call on \(combinerMovedCall) capture-absent images; the later revisions moved the call on \(revisionsMovedCall)")
        lines.append("correct: " + labelled.sorted { $0.key < $1.key }.map { "\($0.key) \(correct[$0.key] ?? 0) of \($0.value)" }.joined(separator: ", "))
        lines.append("calls: " + finalCalls.sorted { $0.key < $1.key }.map { label, calls in
            "\(label) " + ["real", "inconclusive", "generated"].map { "\($0) \(calls[$0] ?? 0)" }.joined(separator: " / ")
        }.joined(separator: "; "))
        return lines.joined(separator: "\n")
    }
}
