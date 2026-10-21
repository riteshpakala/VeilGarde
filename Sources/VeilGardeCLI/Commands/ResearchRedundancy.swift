//
//  ResearchRedundancy.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde research redundancy`: the redundancy check (RedundancyStudy) on final_mixed's
//        tile cache, the store's rows and the scratch store's noiseprint, its report and its table.
//  PIN:  CPU work on cached tiles and stored features. The golden arm's columns come from a core
//        report (`research core` or its `--combine`) or are named. Writes
//        <work area>/research/redundancy-<stamp>.json.
//

import ArgumentParser
import Foundation
import VeilGarde

extension ResearchCommand {
    struct Redundancy: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "redundancy", abstract: "Ask whether the noiseprint's and the fusion head's signals are already in the warp residual, arm by arm.",
            discussion: "Needs the noiseprint of final_mixed's store rows in a scratch store: features extract <list> --columns noiseprint --shard final_mixed_np --store <aux>.")
        @Option(name: .customLong("golden-report"), help: "A core report or core-golden report whose golden columns make the golden arm.") var goldenReport: String?
        @Option(help: "The golden arm's features, comma separated (instead of --golden-report).") var golden: String?
        @Option(help: "Bootstrap resamples per comparison.") var resamples = 1000
        @Option(help: "The warp tile cache (default: <work area>/store/tiles/final_mixed).") var tiles: String?
        @Option(help: "The feature store (default: <work area>/store/shards).") var store: String?
        @Option(help: "The scratch store holding final_mixed_np (default: <work area>/store/aux).") var aux: String?
        @Option(help: "Write the report here too (`-` for stdout).") var json: String?
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let area = try workArea.resolve()
                var s = RedundancySettings()
                s.resamples = resamples
                if let golden { s.golden = try WarpFeatures.columns(named: golden.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
                if let goldenReport {
                    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: datasetURL(goldenReport))) as? [String: Any]
                    guard let columns = (object?["golden"] as? [String: Any])?["columns"] as? [Int] else { throw VeilGardeFailure.data("\(goldenReport) names no golden columns") }
                    s.golden = columns
                }
                let inputs = RedundancyStudy.Inputs(tiles: tiles.map(datasetURL) ?? area.tiles.appendingPathComponent("final_mixed", isDirectory: true),
                                                    store: store.map(datasetURL) ?? area.shards,
                                                    aux: aux.map(datasetURL) ?? area.root.appendingPathComponent("store/aux", isDirectory: true),
                                                    bundle: try ShippedBundle.verified())
                let report = try RedundancyStudy.run(inputs, settings: s, note: note)
                let file = try ResearchCommand.output(area, "redundancy")
                try JSONCoding.write(report, to: file)
                if let json { try emitJSON(try JSONCoding.prettyEncoder().encode(report), to: json) }
                print(Self.table(report))
                note("report: \(file.path)")
            }
        }

        static func table(_ r: RedundancyReport) -> String {
            func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
            var lines = ["redundancy: " + r.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")]
            for arm in r.arms {
                lines.append("\(arm.name) (\(arm.features.joined(separator: ", "))); cuts \(String(format: "%.4f / %.4f", arm.cuts.realAtOrBelow, arm.cuts.generatedAtOrAbove))")
                for x in arm.reconstruction {
                    lines.append("  reconstructs the \(x.target) call: " + String(format: "AUC %.4f on %d images (%d positive), Spearman %.3f — %@", x.auc, x.images, x.positives, x.spearman,
                                                                                    x.reconstructed ? "reconstructed (RR2)" : "not reconstructed"))
                }
                lines.append("  cross-fitted AUC: " + arm.aucs.sorted { $0.key < $1.key }.map { String(format: "%@ %.4f", $0.key, $0.value) }.joined(separator: "; "))
                for g in arm.gains {
                    let c = g.comparison
                    lines.append("  " + pad(g.name, 42) + String(format: "%+.4f [%+.4f, %+.4f], moved %d — %@", c.delta, c.low, c.high, c.changedCalls, g.verdict))
                }
                let v = arm.coverage
                lines.append("  combiner replay on \(v.captureAbsent) capture-absent images: the noiseprint moves \(v.noiseprintMoved) calls, \(v.noiseprintMovedRight) to the right label; the sensor call had \(v.movedSensorRight) of them right")
                lines.append("  fusion against the warp lens's own call: \(v.fusionWarpDisagree) differ, fusion right \(v.fusionRight), warp right \(v.warpRight)")
                let c = arm.camera
                lines.append("  \(r.settings.cameraPool) (\(c.images)): sensor real and noiseprint camera \(c.sensorRealCamera), sensor real only \(c.sensorRealNoCamera), noiseprint camera only \(c.sensorOtherCamera), neither \(c.sensorOtherNoCamera)")
            }
            return lines.joined(separator: "\n")
        }
    }
}
