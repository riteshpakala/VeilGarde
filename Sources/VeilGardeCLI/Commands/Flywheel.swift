//
//  Flywheel.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde flywheel`: the regime that grows the fusion head and the specialist stack. `init` seeds the live
//        bundle and the battery, `seed` copies a feature store in, `acquire` fetches images from the
//        collectors into a features-only shard (no image is written), `gap` says where the base
//        is weakest and which jobs would fill it, `ingest` measures labeled local images into a
//        new shard, `candidates` trains the weekly candidates and writes their review,
//        `agreement` measures the north star, `battery` gates a bundle, `promote` and `rollback`
//        are the only writers of live/, `status` says what is live.
//  PIN:  Battery and promote run the full detector in process, one image at a time (one MLX
//        workload); everything else is CPU work on stored features. Exit 1 on a failed battery.
//

import ArgumentParser
import Foundation
import VeilGarde

struct FlywheelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flywheel", abstract: "Grow the fusion head and the specialist stack: the live bundle, the features-only store, candidates, the battery, promote and rollback.",
        discussion: "Run `flywheel init` once; then ingest or seed, `candidates`, review REVIEW.md, and `promote` what passes.",
        subcommands: [Init.self, Seed.self, Acquire.self, Gap.self, IngestImages.self, Candidates.self, AgreementCommand.self, Battery.self, Promote.self, Rollback.self, Status.self])

    static func area(_ options: WorkAreaOptions) throws -> FlywheelArea { FlywheelArea(try options.resolve()) }

    /// The battery as promote and rollback run it: the full detector on a bundle, the work area's spec and floors.
    static func battery(_ area: FlywheelArea) -> Promoter.Battery {
        { gate, root in
            ShippedBundle.registerWeightFolders(workArea: area.area)
            let spec = try BatterySpec.load(area.batterySpec)
            let report = try BatteryRunner.run(spec: spec, specURL: area.batterySpec, gate: gate, baselineURL: area.batteryBaseline,
                                               verdicts: DetectorVerdicts(bundle: try DetectorBundle.load(root)),
                                               vars: spec.resolvedVars(images: area.batteryImages), note: note)
            note(report.table)
            return report
        }
    }

    struct Init: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "init", abstract: "Seed <work area>/live from the shipped bundle and <work area>/battery from the shipped spec and floors.")
        @Flag(help: "Only install the shipped battery spec and floors, replacing older ones (kept under battery/retired/); live/ is left alone.")
        var battery = false
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let area = try FlywheelCommand.area(workArea)
                if battery {
                    let r = try area.replaceBattery(spec: try FlywheelResources.batterySpec(), baseline: try FlywheelResources.batteryBaseline())
                    print("battery: \(area.batterySpec.path) (spec \(r.batterySpecSHA256.prefix(12)), floors \(r.batteryBaselineSHA256.prefix(12)))")
                    print(r.retired.map { "retired: \($0)" } ?? "retired: nothing (the shipped pair was already installed)")
                    return
                }
                let report = try area.initialize(from: try ShippedBundle.verified(), spec: try FlywheelResources.batterySpec(),
                                                 baseline: try FlywheelResources.batteryBaseline())
                print("live: \(area.live.path) (\(report.artifacts) artifacts)")
                print("battery: \(area.batterySpec.path) (spec \(report.batterySpecSHA256.prefix(12)), floors \(report.batteryBaselineSHA256.prefix(12)))")
            }
        }
    }

    struct Seed: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "seed", abstract: "Copy a feature store's shards into <work area>/store/shards.")
        @Option(help: "The store to copy from (read only).") var from: String
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let area = try FlywheelCommand.area(workArea)
                let report = try StoreSeed.copy(from: datasetURL(from), to: area.store, note: note)
                print("\(report.copied.count) shards copied (\(report.rows) rows, \(report.bytes / 1_000_000) MB); \(report.kept.count) already there")
            }
        }
    }

    struct Acquire: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "acquire", abstract: "Fetch images from the collectors into a new features-only shard; the images are measured in memory and dropped.")
        @Option(help: "The day's image budget, split across the jobs (at least 50 each).") var budget: Int = 1000
        @Option(help: "Images per job, overriding the budget's split.") var per: Int?
        @Option(help: "gap (the last `flywheel gap`), default, test (keyless: Wikimedia and the Met), or a targets .json.") var targets: String = "gap"
        @Option(help: "The shard's name (default: acquire_<date>).") var shard: String?
        @Flag(name: .customLong("no-route"), help: "Skip the CLIP router (generated images keep their job's category, NSFW is not flagged).") var noRoute = false
        @Flag(name: .customLong("dry-run"), help: "List the jobs and stop.") var dryRun = false
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let area = try FlywheelCommand.area(workArea)
                ShippedBundle.registerWeightFolders(workArea: area.area)
                let shipped = try AcquireTargets.shipped()
                let gapFile = area.root.appendingPathComponent("acquire/targets.json")
                let jobs: [AcquireJob]
                switch targets {
                case "test": jobs = shipped.testJobs
                case "default": jobs = shipped.defaultJobs
                case "gap":
                    if FileManager.default.fileExists(atPath: gapFile.path) { jobs = try JSONCoding.read(GapReport.self, from: gapFile).jobs }
                    else { note("acquire: no gap report yet (\(gapFile.path)); running the default jobs"); jobs = shipped.defaultJobs }
                case let path: jobs = try JSONCoding.read([AcquireJob].self, from: datasetURL(path))
                }
                let perJob = per ?? max(50, budget / max(1, jobs.count))
                for j in jobs { note("  job: \(j.source) \(j.category)/\(j.label) '\(j.query.prefix(50))'" + (j.gap.map { " (gap \($0))" } ?? "")) }
                if dryRun { print("\(jobs.count) jobs × \(perJob) images"); return }
                let router: CategoryRouter? = noRoute ? nil : try CategoryRouter()
                if router != nil { _ = try CLIPLens.shared.tower() }
                let report = try Acquirer(area: area, note: note).run(jobs, perJob: perJob, extractor: FeatureExtractor(), router: router, shard: shard)
                for j in report.jobs {
                    print("\(j.job.source) \(j.job.category)/\(j.job.label): " + (j.skipped.map { "skipped, \($0)" } ?? "\(j.accepted) kept of \(j.fetched) fetched, rejected \(j.rejected)"))
                }
                print(report.shard.map { "\($0): \(report.rows) rows in \(area.store.path) (\(Int(report.seconds)) s); no image was written" } ?? "no rows kept")
            }
        }
    }

    struct Gap: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "gap", abstract: "Rank the store's (domain, category, label) buckets by the base's error plus its disagreement with the pooled verdict, and write the jobs that fill the worst.")
        @Option(help: "Comma-separated shards to read (default: all).") var shards: String?
        @Flag(name: .customLong("no-write"), help: "Print the report without writing acquire/targets.json.") var noWrite = false
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let area = try FlywheelCommand.area(workArea)
                let report = try GapMiner.mine(try area.liveBundle(), store: FeatureStore(directory: area.store),
                                               shards: shards.map { $0.split(separator: ",").map(String.init) }, targets: try AcquireTargets.shipped())
                print(report.table)
                if !noWrite {
                    let out = area.root.appendingPathComponent("acquire/targets.json")
                    try JSONCoding.write(report, to: out)
                    print("\nwrote \(report.jobs.count) jobs → \(out.path)")
                } else {
                    print("\n\(report.jobs.count) jobs (not written)")
                }
            }
        }
    }

    struct IngestImages: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ingest", abstract: "Measure labeled images into a new store shard (DINOv2's two views and the capture values); the images are read and dropped.")
        @Argument(help: "A .jsonl of {path, label, category, source?, golden?, gen_family?}.") var items: String
        @Option(help: "The new shard's name.") var shard: String
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                ShippedBundle.registerWeightFolders()
                let area = try FlywheelCommand.area(workArea)
                let list = try JSONCoding.readLines(ExtractionItem.self, from: datasetURL(items))
                let report = try Ingest.run(list, shard: shard, area: area, note: note)
                print(String(format: "%@: %d rows written, %d already in the store, %d skipped, %.1fs", report.shard, report.rows, report.skippedKnown, report.failed.count, report.seconds))
            }
        }
    }

    struct Candidates: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "candidates", abstract: "Train the weekly candidates (a warm-started base and the atlas heads) on top of live, measure them, write REVIEW.md.")
        @Option(help: "The candidate's id (default: weekly-<date>).") var id: String?
        @Flag(help: "Replace a candidate with the same id.") var replace = false
        @Flag(help: "Print the plan and stop.") var plan = false
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let area = try FlywheelCommand.area(workArea)
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyyMMdd"
                let recipe = WeeklyCandidates.recipe(id: id ?? "weekly-\(f.string(from: Date()))")
                if plan {
                    let p = try TrainingEngine(area: area.area, parent: area.live, store: area.store).plan(recipe)
                    print(p.summary)
                    return
                }
                let outcome = try WeeklyCandidates.run(recipe, area: area, replace: replace) { if let line = $0.line { note(line) } }
                print("candidate: \(outcome.candidate.root.path)")
                print("review:    \(outcome.review.path)")
                print(String(format: "agreement: %.4f live → %.4f candidate; AUC gap %.4f → %.4f", outcome.liveAgreement.agreementAll,
                             outcome.candidateAgreement.agreementAll, outcome.liveAgreement.aucGap, outcome.candidateAgreement.aucGap))
            }
        }
    }

    struct AgreementCommand: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "agreement", abstract: "Measure the north star on the store: base ↔ pooled agreement and both AUCs, for live or a bundle.")
        @Option(help: "A bundle to measure instead of live (a candidate).") var bundle: String?
        @Flag(name: .customLong("no-log"), help: "Do not append the row to flywheel_metrics.csv.") var noLog = false
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let area = try FlywheelCommand.area(workArea)
                let target = try bundle.map { try ModelBundle.load(datasetURL($0)) } ?? area.liveBundle()
                let r = try Agreement.measure(target, store: FeatureStore(directory: area.store), label: bundle.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "live")
                if !noLog { try Agreement.append(r, to: area.metricsCSV) }
                print(String(format: "%@: %d rows (camera %d, processed %d)", r.bundle, r.rows, r.camera, r.processed))
                print(String(format: "  agreement %.4f all, %@ camera, %@ processed", r.agreementAll, r.agreementCamera.map { String(format: "%.4f", $0) } ?? "n/a",
                             r.agreementProcessed.map { String(format: "%.4f", $0) } ?? "n/a"))
                print(String(format: "  test %d rows: base AUC %.4f (real FPR %.3f, gen FNR %.3f); pooled AUC %.4f (real FPR %.3f, gen FNR %.3f); gap %+.4f",
                             r.testRows, r.baseAUC, r.baseRealFPR, r.baseGenFNR, r.weightedAUC, r.weightedRealFPR, r.weightedGenFNR, r.aucGap))
            }
        }
    }

    struct Battery: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "battery", abstract: "Run the battery on live (or a bundle): HARD groups for --gate promote, every group for full.")
        @Option(help: "promote or full.") var gate: String = BatterySpec.Gate.full.rawValue
        @Option(help: "A bundle to gate instead of live (a candidate).") var bundle: String?
        @Option(help: "Write the report JSON here (`-` for stdout).") var json: String?
        @Flag(help: "Re-record the ratchet floors from this run (full gate only, with --yes-i-reviewed).") var rebaseline = false
        @Flag(name: .customLong("yes-i-reviewed"), help: "Confirms a rebaseline was reviewed.") var reviewed = false
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                guard let g = BatterySpec.Gate(rawValue: gate) else { throw VeilGardeFailure.usage("--gate is promote or full") }
                if rebaseline && !(g == .full && reviewed) { throw VeilGardeFailure.usage("--rebaseline needs --gate full and --yes-i-reviewed") }
                let area = try FlywheelCommand.area(workArea)
                ShippedBundle.registerWeightFolders(workArea: area.area)
                let root = bundle.map(datasetURL) ?? area.live
                let spec = try BatterySpec.load(area.batterySpec)
                let report = try BatteryRunner.run(spec: spec, specURL: area.batterySpec, gate: g, baselineURL: area.batteryBaseline,
                                                   verdicts: DetectorVerdicts(bundle: try DetectorBundle.load(root)),
                                                   vars: spec.resolvedVars(images: area.batteryImages), rebaseline: rebaseline, note: note)
                let saved = area.batteryRuns.appendingPathComponent("\(FlywheelArea.stamp())-\(g.rawValue).json")
                try JSONCoding.write(report, to: saved)
                if let json { try emitJSON(try JSONCoding.prettyEncoder().encode(report), to: json) }
                print(report.table)
                note("report: \(saved.path)")
                if !report.pass { throw ExitCode(1) }
            }
        }
    }

    struct Promote: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "promote", abstract: "Promote one slot from a candidate into live, behind its battery; a failure restores live.")
        @Argument(help: "base, combiner, or a head (art, blur, human, cgi, preview, art-pair, screenshot, semtile).") var slot: String
        @Option(help: "The candidate bundle.") var from: String
        @Flag(name: .customLong("dry-run"), help: "Run every check and print what would change; write nothing, run no battery.") var dryRun = false
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let area = try FlywheelCommand.area(workArea)
                let s = try FlywheelSlot(parsing: slot)
                let promoter = Promoter(area: area, battery: FlywheelCommand.battery(area), note: note)
                if dryRun {
                    let preview = try promoter.preview(s, from: datasetURL(from), store: FeatureStore(directory: area.store))
                    print("would promote " + preview.summary)
                    return
                }
                let record = try promoter.promote(s, from: datasetURL(from), store: FeatureStore(directory: area.store))
                print("promoted \(record.slot): \(record.fromSHA256?.prefix(12) ?? "none") → \(record.toSHA256?.prefix(12) ?? "?") (battery PASS, snapshot \(record.snapshot ?? "?"))")
            }
        }
    }

    struct Rollback: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rollback", abstract: "Restore live from a snapshot in live/.history (the newest by default), then run the full battery.")
        @Argument(help: "The snapshot's stamp.") var stamp: String?
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let area = try FlywheelCommand.area(workArea)
                let record = try Promoter(area: area, battery: FlywheelCommand.battery(area), note: note).rollback(to: stamp)
                print("rolled back to \(record.snapshot ?? "?") (battery \(record.battery ?? "?"))")
                if record.battery != "PASS" { throw ExitCode(1) }
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "What is live, what moved last, and the snapshots to roll back to.")
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let area = try FlywheelCommand.area(workArea)
                let live = try area.liveBundle()
                print("live: \(live.root.path)")
                for a in live.manifest.artifacts { print("  \(a.slot.padding(toLength: 22, withPad: " ", startingAt: 0)) \(a.sha256.prefix(12))  \(a.frozen ? "frozen " : "       ")\(a.file)") }
                for e in live.manifest.history.suffix(5) { print("  \(e.kind.rawValue) \(e.slot) \(e.date)") }
                let snapshots = Promoter(area: area, battery: { _, _ in throw VeilGardeFailure.internalError("status runs no battery") }).snapshots()
                print("snapshots: \(snapshots.isEmpty ? "none" : snapshots.suffix(5).joined(separator: ", "))")
                let shards = FeatureStore(directory: area.store).shardNames()
                print("store: \(shards.count) shards in \(area.store.path)")
            }
        }
    }
}
