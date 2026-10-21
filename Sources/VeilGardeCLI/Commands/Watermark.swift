//
//  Watermark.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde watermark`: a crop-robust signature read off an image's warp fragility
//        pattern. `sign` prints it (vw1 text, or JSON); `match` finds where an image (a crop, a
//        re-encode) sits on a signature; `verify` is match with the verdict as the exit code;
//        `accept` runs v1's acceptance on final_mixed and evaluates its kill criterion;
//        `invariance` signs a set of images and, against a baseline, fails on any change.
//  PIN:  Native resolution, one MLX workload. `accept` and `invariance` write only their reports.
//

import ArgumentParser
import Foundation
import VeilGarde

struct WatermarkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watermark", abstract: "Sign an image by its warp fragility pattern, and find a crop or a re-encode of it again.",
        discussion: "v1 is a design under measurement: run `watermark accept` before relying on it.",
        subcommands: [Sign.self, Match.self, Verify.self, Accept.self, Invariance.self])

    static func signature(_ text: String) throws -> WatermarkSignature {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("vw1:") { return try WatermarkSignature(compact: trimmed) }
        let url = datasetURL(trimmed)
        let body = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("vw1:") { return try WatermarkSignature(compact: body) }
        return try JSONDecoder().decode(WatermarkSignature.self, from: Data(body.utf8))
    }

    struct Sign: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "sign", abstract: "Print an image's watermark signature (vw1 text, or JSON with --json).")
        @Argument(help: "The image.") var image: String
        @Flag(help: "JSON instead of vw1 text.") var json = false

        func run() throws {
            guarded {
                let sig = try Watermark.sign(try loadImage(image))
                if json { try emitJSON(try JSONCoding.prettyEncoder().encode(sig), to: "-") } else { print(sig.compact) }
                note("\(sig.rows)×\(sig.cols) tiles, \(sig.codes.count) sections, \(sig.measuredBits) bits, cid \(sig.cid.prefix(16))")
            }
        }
    }

    struct Match: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "match", abstract: "Find where an image sits on a signature: offset, phase, score and its z-score.")
        @Argument(help: "The image (a crop or a re-encode of a signed one).") var image: String
        @Argument(help: "The signature: vw1 text, or a file holding vw1 text or JSON.") var signature: String
        @Option(help: "Grid phases in pixels, comma-separated.") var phases: String = "0,8,16,24"
        @Flag(help: "JSON instead of text.") var json = false

        func run() throws {
            guarded {
                let p = phases.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                let r = try Watermark.match(try loadImage(image), against: try WatermarkCommand.signature(signature), options: MatchOptions(phases: p))
                if json { try emitJSON(try JSONCoding.prettyEncoder().encode(r), to: "-"); return }
                print(String(format: "%@: score %.4f over %d bits (z %.1f); offset (%d, %d) tiles at phase (%d, %d) px, the image's origin at (%d, %d) on the signed image",
                             r.matched ? "match" : "no match", r.score, r.bitsCompared, r.zScore, r.offsetX, r.offsetY, r.phaseX, r.phaseY, r.pixelX, r.pixelY))
            }
        }
    }

    struct Verify: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "verify", abstract: "Exit 0 when the image matches the signature, 1 when it does not.")
        @Argument(help: "The image.") var image: String
        @Argument(help: "The signature: vw1 text, or a file holding vw1 text or JSON.") var signature: String

        func run() throws {
            guarded {
                let r = try Watermark.match(try loadImage(image), against: try WatermarkCommand.signature(signature))
                print(String(format: "%@ (score %.4f, %d bits, z %.1f)", r.matched ? "match" : "no match", r.score, r.bitsCompared, r.zScore))
                if !r.matched { throw ExitCode(1) }
            }
        }
    }

    struct Accept: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "accept", abstract: "v1's acceptance run on a seeded final_mixed sample: crops, JPEG, false matches, the kill criterion.")
        @Option(help: "Images to sample (half real, half generated).") var n: Int = 200
        @Option(help: "final_mixed's folder (manifest.csv) or a dataset.jsonl (default: final_mixed under VEILGARDE_DATASETS, else the work area's datasets/).") var dataset: String?
        @Option(help: "The sample's and the crops' seed.") var seed: UInt64 = 0
        @Option(help: "Grid phases in pixels, comma-separated.") var phases: String = "0,8,16,24"
        @Option(help: "Write the report JSON here.") var out: String?
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                _ = try workArea.resolve()
                guard let dataset = dataset.map(datasetURL) ?? WorkArea.datasets().map({ $0.appendingPathComponent("final_mixed") }) else {
                    throw VeilGardeFailure.usage("no dataset: pass --dataset or set VEILGARDE_DATASETS")
                }
                let sample = AcceptanceSample.sample(try AcceptanceSample.dataset(dataset), perLabel: max(1, n / 2), seed: seed)
                var settings = AcceptanceSettings()
                settings.seed = seed
                settings.phases = phases.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                note("accept: \(sample.count) images from \(dataset.path)")
                // Each image's row as it is measured, so a long run that stops keeps what it measured.
                let rowsURL = out.map { datasetURL($0).deletingPathExtension().appendingPathExtension("rows.jsonl") }
                let rows = try rowsURL.map { try JSONLWriter(url: $0, truncate: true) }
                let report = try WatermarkAcceptance.run(sample.map { ($0.url, $0.label) }, settings: settings, note: note,
                                                         measured: { try? rows?.append($0) })
                let s = report.summary
                print(String(format: "images %d; self-match %.1f%%; crop matched with its offset %.1f%%; JPEG q75 median score %.3f", s.images, s.selfMatchRate * 100,
                             s.cropMatchRate * 100, s.jpegMedianScore))
                print(String(format: "cross-image false matches at 0.75: %.1f%% (median cross score %.3f)", s.crossFalseMatchRate * 100, s.crossMedianScore))
                if let t = s.operatingThreshold { print(String(format: "operating point: threshold %.2f, crop recall %.1f%%, false matches %.1f%%", t, (s.operatingRecall ?? 0) * 100, (s.operatingFalseMatchRate ?? 0) * 100)) }
                print("bit balance (E, S, SE, NE): " + s.bitBalance.map { String(format: "%.3f", $0) }.joined(separator: ", "))
                for (k, v) in s.resizedMatchRate.sorted(by: { $0.key > $1.key }) {
                    print(String(format: "resized %@× (every %d-th image): matched %.1f%%", k, settings.resizeEvery, v * 100))
                }
                print(s.killed ? "v1 KILLED: " + s.reasons.joined(separator: "; ") : "v1 passes its acceptance")
                if let out { try JSONCoding.write(report, to: datasetURL(out)); note("report: \(out)") }
            }
        }
    }

    struct Invariance: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "invariance", abstract: "Sign images exactly as `sign` does and record each signature; with --baseline, exit 1 on any difference.",
            discussion: "A gate for changes near the warp residual: take the baseline before the change and re-run after every build. One MLX workload.")
        @Option(help: "A folder (searched recursively), a text file of image paths, or an image; repeatable.") var images: [String]
        @Option(help: "A previous invariance report to compare against.") var baseline: String?
        @Option(help: "Write the report here.") var out: String

        func run() throws {
            guarded {
                let urls = try images.flatMap(imageInputs)
                guard !urls.isEmpty else { throw VeilGardeFailure.usage("no images found in \(images.joined(separator: ", "))") }
                note("invariance: \(urls.count) images")
                let started = Date()
                let report = WatermarkInvariance.measure(urls, note: note)
                try JSONCoding.write(report, to: datasetURL(out))
                print(String(format: "signed %d images (%d skipped) in %.1fs", report.images.count, report.skipped.count, Date().timeIntervalSince(started)))
                for s in report.skipped { print("skipped \(s)") }
                note("report: \(out)")
                guard let baseline else { return }
                let reference = try JSONCoding.read(InvarianceReport.self, from: datasetURL(baseline))
                let differences = WatermarkInvariance.compare(baseline: reference, current: report)
                if differences.isEmpty {
                    print("invariant: all \(reference.images.count) signatures equal the baseline")
                    return
                }
                for d in differences { print("DIFFERENT \(d.path) \(d.field): \(d.baseline) → \(d.current)") }
                print("\(differences.count) differences from the baseline")
                throw ExitCode(1)
            }
        }
    }
}
