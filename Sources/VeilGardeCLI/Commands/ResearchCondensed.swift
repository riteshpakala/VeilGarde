//
//  ResearchCondensed.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde research condensed`: trains the condensed model's pre-registered arms on MLX
//        (CondensedTrainer), judges each by the admission rules, and writes the weights and the
//        report for measurement.
//  PIN:  One MLX workload. Reads final_mixed's tile cache, the store's rows, the scratch store
//        (the noiseprint shard and the battery's) and the battery's tile cache. Writes
//        <work area>/research/condensed-<stamp>.json and the weights under
//        <work area>/research/condensed-<stamp>/; nothing reaches a bundle.
//

import ArgumentParser
import Foundation
import VeilGarde

extension ResearchCommand {
    struct Condensed: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "condensed", abstract: "Train the condensed model's arms on MLX and judge them by the admission rules fixed before the run.",
            discussion: "Needs the scratch store's final_mixed_np and battery_all shards and the battery's tile cache (features tiles <battery.jsonl>). One MLX workload.")
        @Option(name: .customLong("golden-report"), help: "A core or core-golden report whose golden columns make the golden core.") var goldenReport: String?
        @Option(help: "The golden core's features, comma separated (instead of --golden-report).") var golden: String?
        @Option(help: "Arms to run, comma separated (default: all).") var arms: String?
        @Option(help: "The most epochs per run.") var epochs = 40
        @Option(help: "Seeds, comma separated; the first is the candidate.") var seeds = "0,1,2"
        @Option(help: "The warp tile cache (default: <work area>/store/tiles/final_mixed).") var tiles: String?
        @Option(help: "The feature store (default: <work area>/store/shards).") var store: String?
        @Option(help: "The scratch store (default: <work area>/store/aux).") var aux: String?
        @Option(name: .customLong("battery-tiles"), help: "The battery's tile cache (default: <work area>/store/tiles/battery).") var batteryTiles: String?
        @Option(help: "Write the report here too (`-` for stdout).") var json: String?
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let area = try workArea.resolve()
                var s = CondensedSettings()
                s.epochs = epochs
                s.seeds = try seeds.split(separator: ",").map { text in
                    guard let v = UInt64(text.trimmingCharacters(in: .whitespaces)) else { throw VeilGardeFailure.usage("--seeds is a list of integers, not \(seeds)") }
                    return v
                }
                if let arms { s.arms = arms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                if let golden { s.golden = try WarpFeatures.columns(named: golden.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
                if let goldenReport {
                    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: datasetURL(goldenReport))) as? [String: Any]
                    guard let columns = (object?["golden"] as? [String: Any])?["columns"] as? [Int] else { throw VeilGardeFailure.data("\(goldenReport) names no golden columns") }
                    s.golden = columns
                }
                let file = try ResearchCommand.output(area, "condensed")
                let weights = file.deletingPathExtension()
                let inputs = CondensedTrainer.Inputs(tiles: tiles.map(datasetURL) ?? area.tiles.appendingPathComponent("final_mixed", isDirectory: true),
                                                     store: store.map(datasetURL) ?? area.shards,
                                                     aux: aux.map(datasetURL) ?? area.root.appendingPathComponent("store/aux", isDirectory: true),
                                                     batteryTiles: batteryTiles.map(datasetURL) ?? area.tiles.appendingPathComponent("battery", isDirectory: true),
                                                     bundle: try ShippedBundle.verified(), output: weights)
                let report = try CondensedTrainer.run(inputs, settings: s, note: note)
                try JSONCoding.write(report, to: file)
                if let json { try emitJSON(try JSONCoding.prettyEncoder().encode(report), to: json) }
                print(Self.table(report))
                note("report: \(file.path); weights: \(weights.path)")
            }
        }

        static func table(_ r: CondensedReport) -> String {
            func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
            var lines = ["condensed: " + r.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "),
                         String(format: "comparators on the test images: the trio warp model's vote AUC %.4f, %@ sensor real %@; the shipped fusion head's AUC %.4f (reliance)",
                                r.trioVoteAUC, r.settings.cameraPool, r.trioCameraRealShare.map { String(format: "%.3f", $0) } ?? "—", r.shippedFusionAUC)]
            lines.append("  " + pad("arm", 24) + "params  test AUC (seeds)          boosted  FPR@its recall  HARD battery  camera real  verdict")
            for a in r.arms {
                lines.append("  " + pad(a.arm.name, 24) + String(format: "%6d  %.4f (%.4f ± %.4f)  %.4f   %.3f / %.3f   %2d of %2d      %@  %@", a.parameters, a.model.auc, a.testAUCMean,
                                                                    a.testAUCSpread, a.gbdt.auc, a.fprAtGBDTRecall, a.gbdt.realFPR, a.battery.hardRight, a.battery.hardImages,
                                                                    a.model.cameraRealShare.map { String(format: "%.3f", $0) } ?? "  —  ",
                                                                    a.admissible ? "admissible" : "fails " + a.rules.filter { !$0.passed }.map { String($0.rule.prefix(2)) }.joined(separator: ", ")))
                if !a.battery.wrong.isEmpty { lines.append("    HARD battery wrong: " + a.battery.wrong.joined(separator: ", ")) }
            }
            return lines.joined(separator: "\n")
        }
    }
}
