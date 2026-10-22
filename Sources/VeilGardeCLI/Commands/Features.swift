//
//  Features.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde features`: what the lens measures, without a verdict. `capture` prints the
//        capture signature as a TSV line (peak, valid, native px, present); `extract` measures
//        labeled images into a new store shard (the columns every head and the camera head train
//        on) and keeps nothing of the images.
//

import ArgumentParser
import Foundation
import VeilGarde

struct FeaturesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "features", abstract: "Measure images: the capture signature, and labeled images into the features-only store.",
        subcommands: [Capture.self, Extract.self])

    struct Capture: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "capture", abstract: "Print the native capture signature as a TSV line: peak, valid, native px, present.")

        @Argument(help: "The image.") var image: String

        func run() throws {
            guarded {
                let cs = CaptureLens.signature(try loadImage(image))
                print(String(format: "%.3f\t%@\t%d\t%@", cs.peak, cs.valid ? "true" : "false", cs.nativePixels, cs.present ? "true" : "false"))
            }
        }
    }

    struct Extract: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "extract", abstract: "Measure labeled images into a new feature-store shard; the images are read and dropped.")
        @Argument(help: "A folder of images, a text file of paths, or a .jsonl of {path, label, category, source?, golden?, gen_family?}.") var input: String
        @Option(help: "The new shard's name.") var shard: String
        @Option(help: "The label for a folder or path list: 1 generated, 0 real.") var label: Int?
        @Option(help: "The category for a folder or path list (art, blur, human, cgi, preview, photo, …).") var category: String?
        @Option(help: "The source tag for a folder or path list.") var source: String?
        @Option(help: "The feature store directory (default: <work area>/store/shards).") var store: String?
        @Option(help: "Read at most this many images.") var limit: Int?
        @Option(help: "small, xsmall or xxsmall.") var dino: String = DinoVariant.small.rawValue
        @Option(help: "Measure only these columns, comma separated (dino_norm, dino_fusion, cap); the rest are NaN.") var columns: String?
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                ShippedBundle.registerWeightFolders()
                guard let variant = DinoVariant(rawValue: dino) else { throw VeilGardeFailure.usage("--dino is small, xsmall or xxsmall") }
                let measured = try columns.map { list in
                    Set(try list.split(separator: ",").map { name -> FeatureColumn in
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        guard let column = FeatureColumn(rawValue: trimmed) else {
                            throw VeilGardeFailure.usage("--columns names \(FeatureColumn.allCases.map(\.rawValue).joined(separator: ", ")), not \(trimmed)")
                        }
                        return column
                    })
                } ?? Set(FeatureColumn.allCases)
                let url = datasetURL(input)
                var items: [ExtractionItem]
                if url.pathExtension == "jsonl" {
                    items = try JSONCoding.readLines(ExtractionItem.self, from: url)
                } else {
                    guard let label, let category else { throw VeilGardeFailure.usage("a folder or a path list needs --label and --category") }
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    let paths = isDirectory.boolValue ? ShardExtractor.images(in: url).map(\.path)
                        : try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    items = paths.map { ExtractionItem(path: $0, label: label, category: category, source: source) }
                }
                if let limit { items = Array(items.prefix(limit)) }
                let storeURL = try store.map(datasetURL) ?? workArea.resolve().root.appendingPathComponent("store/shards", isDirectory: true)
                let extractor = FeatureExtractor(variant: variant, columns: measured)
                note("extract: \(items.count) images → \(storeURL.path)/\(shard)")
                let report = try ShardExtractor.extract(items, shard: shard, store: FeatureStore(directory: storeURL), extractor: extractor, note: note)
                print(String(format: "%@: %d rows written, %d already in the store, %d skipped, %.1fs", report.shard, report.rows, report.skippedKnown,
                             report.failed.count, report.seconds))
            }
        }
    }
}
