//
//  ResearchCore.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde research core`: the core study (CoreStudy) on the work area's tile cache, its
//        report and its table; `--combine` applies the golden rule across the stem-split and the
//        left-out-pool reports.
//  PIN:  CPU work on cached tiles, no MLX. Writes <work area>/research/core-<stamp>.json (or
//        core-golden-<stamp>.json). No flag moves a rule's tolerance: they are fixed in
//        CoreSettings, which every report carries.
//

import ArgumentParser
import Foundation
import VeilGarde

/// R2 across runs, as `research core --combine` writes it.
struct CoreGoldenAcross: Codable {
    var date: Date
    var reports: [String]
    var perRun: [CoreGolden]
    var golden: CoreGolden
}

extension ResearchCommand {
    struct Core: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "core", abstract: "Refit the warp tile model on pre-registered feature subsets, 19 wide, and measure what moves the majority route.",
            discussion: "The rules are fixed in code and written into the report. About 60 refits of the deployed shape on the tile cache; CPU only.")
        @Option(help: "Registered arms to run, comma separated (default: all; all19, the seed controls and the trio always run).") var arms: String?
        @Option(help: "Bootstrap resamples per comparison.") var resamples = 1000
        @Option(help: "The warp tile cache (default: <work area>/store/tiles/final_mixed).") var tiles: String?
        @Option(name: .customLong("leave-pool-out"), help: "A source pool to take out of train and validation and score whole (iphone).") var leavePoolOut: String?
        @Flag(name: .customLong("no-forward"), help: "Skip the forward selection.") var noForward = false
        @Option(parsing: .upToNextOption, help: "Instead of a run: core reports to judge together by the golden rule, the stem split first.") var combine: [String] = []
        @Option(help: "Write the report here too (`-` for stdout).") var json: String?
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let area = try workArea.resolve()
                if !combine.isEmpty {
                    let reports = try combine.map { try JSONCoding.read(CoreReport.self, from: datasetURL($0)) }
                    let across = CoreGoldenAcross(date: Date(), reports: combine.map { datasetURL($0).path }, perRun: reports.map(\.golden),
                                                  golden: CoreStudy.golden(across: reports))
                    let file = try ResearchCommand.output(area, "core-golden")
                    try JSONCoding.write(across, to: file)
                    if let json { try emitJSON(try JSONCoding.prettyEncoder().encode(across), to: json) }
                    for (path, g) in zip(combine, across.perRun) { print("\(path): \(g.name) (\(g.features.joined(separator: ", ")))") }
                    print("golden across \(reports.count) runs: \(across.golden.name) (\(across.golden.features.joined(separator: ", "))); \(across.golden.reason)")
                    print("qualifying in every run: " + (across.golden.qualifying.isEmpty ? "none" : across.golden.qualifying.joined(separator: ", ")))
                    note("report: \(file.path)")
                    return
                }
                var s = CoreSettings()
                s.resamples = resamples
                s.forwardSelection = !noForward
                s.leavePoolOut = leavePoolOut
                s.arms = arms.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                _ = try CoreStudy.chosenArms(s)
                let inputs = CoreStudy.Inputs(tiles: tiles.map(datasetURL) ?? area.tiles.appendingPathComponent("final_mixed", isDirectory: true),
                                              bundle: try ShippedBundle.verified())
                let report = try CoreStudy.run(inputs, settings: s, note: note)
                let file = try ResearchCommand.output(area, "core")
                try JSONCoding.write(report, to: file)
                if let json { try emitJSON(try JSONCoding.prettyEncoder().encode(report), to: json) }
                print(Self.table(report))
                note("report: \(file.path)")
            }
        }

        static func table(_ r: CoreReport) -> String {
            func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
            func share(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "  —  " }
            let p = r.partitions, camera = r.settings.cameraPool
            var lines = [String(format: "core: train %d images (%d tiles), validation %d, scored %d (%d tiles)%@; seed floor %.4f vote AUC",
                                p.trainImages, p.trainTiles, p.validationImages, p.scoredImages, p.scoredTiles,
                                p.leftOutPool.map { ", the \($0) pool's \(p.leftOutImages) images left out of training and scored" } ?? "", r.seedFloor)]
            if let sh = r.shipped {
                lines.append(String(format: "shipped model (reliance: its own corpus): vote AUC %.4f, weighted %.4f; %@ real %@; generated called real %.3f",
                                    sh.metrics.imageMajorityAUC, sh.metrics.imageWeightedAUC, camera, share(sh.cameraRealShare), sh.sensor.generatedCalledReal))
            }
            lines.append("  " + pad("arm", 26) + "cols  tile   weighted vote    vote vs trio [95%]          vs all19  moved  \(pad(camera + " real", 11)) gen→real  R1 / distance / R2")
            for row in r.rows {
                let t = row.againstTrio.vote, a = row.againstAll19.vote
                lines.append("  " + pad(row.arm.name, 26) + String(format: "%4d  %.4f %.4f   %.4f  %+.4f [%+.4f, %+.4f]  %+.4f  %5d  ", row.arm.width, row.metrics.tileAUC,
                                                                     row.metrics.imageWeightedAUC, row.metrics.imageMajorityAUC, t.delta, t.low, t.high, a.delta, a.changedCalls)
                             + pad(share(row.cameraRealShare), 11) + " " + String(format: "%.3f", row.sensor.generatedCalledReal)
                             + "     \(row.needle) / \(row.distance) / \(row.qualifies ? "qualifies" : "—")")
            }
            if !r.forward.isEmpty { lines.append(" forward selection from the trio:") }
            for step in r.forward {
                lines.append(String(format: "  step %d from %@: best %@ %+.4f [%+.4f, %+.4f] — %@", step.step, step.base.joined(separator: ", "), step.best,
                                    step.gain, step.low, step.high, step.stopped.map { "stop: \($0)" } ?? "added"))
            }
            let reference = r.rows[0]
            let golden = r.rows.first { $0.arm.name == r.golden.name } ?? reference
            lines.append(" sensor calls by pool, all19 | \(golden.arm.name) (real / inconclusive / generated):")
            for pool in reference.pools {
                let g = golden.pools.first { $0.pool == pool.pool && $0.label == pool.label }
                lines.append("  " + pad("\(pool.pool) (\(pool.label == 1 ? "generated" : "real"))", 26) + String(format: "%4d  %.3f / %.3f / %.3f  |  %.3f / %.3f / %.3f",
                             pool.images, pool.real, pool.inconclusive, pool.generated, g?.real ?? .nan, g?.inconclusive ?? .nan, g?.generated ?? .nan))
            }
            lines.append("golden (this run): \(r.golden.name) (\(r.golden.features.joined(separator: ", "))) — \(r.golden.reason)")
            return lines.joined(separator: "\n")
        }
    }
}
