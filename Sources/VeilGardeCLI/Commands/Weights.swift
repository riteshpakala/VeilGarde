//
//  Weights.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde weights`: where the neural weights are and whether they are the ones the bundle
//        was built with. `list` shows each weight's search result; `verify` re-hashes them against
//        the shipped manifest and exits 1 on a mismatch or a missing file. `import-dinov2` builds
//        the three DINOv2 files from Hugging Face's
//        checkpoint (downloading it when no file is named), `export-xxsmall` quantizes an xsmall
//        file, and `import-clip` converts CLIP's vision tower from a safetensors checkpoint.
//

import ArgumentParser
import Foundation
import VeilGarde

struct WeightsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "weights", abstract: "List and verify the DINOv2 and CLIP weights.",
                                                    subcommands: [List.self, Verify.self, ImportDINOv2.self, ExportXXSmall.self, ImportCLIP.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "Show where each weight file is found, in search order.")
        @Option(name: .customLong("weights-dir"), help: "A folder searched first.") var weightsDir: String?

        func run() throws {
            guarded {
                ShippedBundle.registerWeightFolders()
                if let weightsDir { WeightLocator.shared.setOverride(URL(fileURLWithPath: (weightsDir as NSString).expandingTildeInPath, isDirectory: true)) }
                print("search path: " + WeightLocator.shared.searchPath().map(\.path).joined(separator: " → "))
                for file in WeightFile.allCases {
                    print("  " + file.rawValue.padding(toLength: 34, withPad: " ", startingAt: 0) + (WeightLocator.shared.url(file)?.path ?? "not found"))
                }
            }
        }
    }

    struct Verify: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "verify", abstract: "Re-hash each weight against the hash the shipped manifest records.")
        @Option(name: .customLong("weights-dir"), help: "A folder searched first.") var weightsDir: String?

        func run() throws {
            guarded {
                ShippedBundle.registerWeightFolders()
                if let weightsDir { WeightLocator.shared.setOverride(URL(fileURLWithPath: (weightsDir as NSString).expandingTildeInPath, isDirectory: true)) }
                var failures = 0
                for expected in ShippedBundle.manifest.weights {
                    guard let url = WeightLocator.shared.url(named: expected.file) else { print("missing  \(expected.file)"); failures += 1; continue }
                    let sha = try ArtifactHashCache.shared.sha256(url)
                    print("\(sha == expected.sha256 ? "ok      " : "MISMATCH") \(expected.file)  \(sha.prefix(12))  \(url.path)")
                    if sha != expected.sha256 { failures += 1 }
                }
                if failures > 0 { throw ArgumentParser.ExitCode(FailureCode.doctor.rawValue) }
            }
        }
    }

    struct ImportDINOv2: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import-dinov2", abstract: "Build dinov2_small, _xsmall and _xxsmall from Hugging Face's facebook/dinov2-small checkpoint.",
            discussion: "With no --from, the checkpoint is downloaded into <work area>/hf. A file already in the output folder is compared tensor by tensor and kept; the new one goes to <out>/imported unless --replace.")
        @Option(help: "The checkpoint: a model.safetensors, or a folder holding one.") var from: String?
        @Option(help: "The output folder (default: <work area>/weights).") var out: String?
        @Option(help: "small, xsmall, xxsmall or all.") var variant: String = "all"
        @Flag(help: "Replace files already in the output folder.") var replace = false
        @Option(name: .customLong("weights-dir"), help: "A folder searched first for the files to compare against.") var weightsDir: String?
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let area = try workArea.resolve()
                ShippedBundle.registerWeightFolders(workArea: area)
                if let weightsDir { WeightLocator.shared.setOverride(datasetURL(weightsDir)) }
                let variants: [DinoVariant]
                if variant == "all" { variants = DinoVariant.allCases } else {
                    guard let v = DinoVariant(rawValue: variant) else { throw VeilGardeFailure.usage("--variant is small, xsmall, xxsmall or all, not \(variant)") }
                    variants = [v]
                }
                let checkpoint = try Dinov2Import.checkpoint(from.map(datasetURL), hfBase: area.root.appendingPathComponent("hf", isDirectory: true))
                let output = out.map(datasetURL) ?? area.weights
                let report = try Dinov2Import.importWeights(checkpoint: checkpoint, variants: variants, output: output, replace: replace,
                                                            reference: { WeightLocator.shared.url($0.weightFile) }, note: note)
                print("checkpoint \(report.checkpoint) (sha256 \(report.checkpointSHA256.prefix(12)))")
                for file in report.files { print(WeightsCommand.describe(file)) }
            }
        }
    }

    struct ExportXXSmall: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export-xxsmall", abstract: "Quantize an xsmall DINOv2 file into xxsmall (8-bit Linear weights in groups of 64), as the runtime quantizes it.")
        @Option(help: "The xsmall file (default: the one the weight search finds).") var from: String?
        @Option(help: "The output file (default: <work area>/weights/imported/dinov2_small_xxsmall.safetensors).") var out: String?
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let area = try workArea.resolve()
                ShippedBundle.registerWeightFolders(workArea: area)
                guard let source = from.map(datasetURL) ?? WeightLocator.shared.url(.dinov2XSmall) else {
                    throw VeilGardeFailure.missing("no xsmall DINOv2 file found; name one with --from")
                }
                let output = out.map(datasetURL) ?? area.weights.appendingPathComponent("imported/\(WeightFile.dinov2XXSmall.rawValue)")
                print(WeightsCommand.describe(try Dinov2Import.exportXXSmall(fromXSmall: source, to: output, reference: WeightLocator.shared.url(.dinov2XXSmall))))
            }
        }
    }

    static func describe(_ file: Dinov2Import.ImportedFile) -> String {
        var line = "\(file.variant): \(file.tensors) tensors → \(file.path) (sha256 \(file.sha256.prefix(12)))"
        if file.keptExisting { line += "; the existing file was kept" }
        if let c = file.comparison {
            if c.sameFile { line += "\n  byte-identical to \(c.reference)" } else {
                line += "\n  against \(c.reference): \(c.identicalBytes) of \(c.tensors) tensors byte-identical, max |Δ| \(String(format: "%.3g", c.maxAbsDifference))"
                    + (c.worst.map { " (\($0))" } ?? "")
                for problem in c.problems.prefix(6) { line += "\n  \(problem)" }
            }
        }
        return line
    }

    struct ImportCLIP: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "import-clip", abstract: "Convert CLIP ViT-B/32's vision tower from a Hugging Face safetensors file into the work area's weights.")
        @Option(help: "The checkpoint: a CLIPModel model.safetensors (or a vision-only one).") var from: String
        @Option(help: "The output file (default: <work area>/weights/clip_vit_b32_vision.safetensors).") var out: String?
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let output = try out.map(datasetURL) ?? workArea.resolve().root.appendingPathComponent("weights/\(WeightFile.clipVision.rawValue)")
                let report = try CLIPImport.convert(from: datasetURL(from), to: output)
                print("\(report.tensors) tensors → \(report.output) (sha256 \(report.sha256.prefix(12)))")
            }
        }
    }
}
