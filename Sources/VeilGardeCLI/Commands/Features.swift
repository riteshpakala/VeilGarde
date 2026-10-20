//
//  Features.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde features`: what the lens measures on one image, without a verdict. `capture`
//        prints the capture signature as Garde's --capture TSV (peak, valid, native px, present);
//        `show` prints the capture values, the screenshot gate's tells and the 19 warp features'
//        means (or every tile with --tiles, or JSON). `tiles` cuts a dataset into the warp
//        trainer's tile cache and `patches` the noiseprint trainer's patches into its cache, both
//        ahead of training; `extract` measures labeled images into a new store shard (the six
//        columns every head and the fusion head train on) and keeps nothing of the images.
//

import ArgumentParser
import Foundation
import VeilGarde

struct FeaturesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "features", abstract: "Measure an image's features: the capture signature, the screenshot gate, the warp tile features.",
        subcommands: [Capture.self, Show.self, Tiles.self, Patches.self, Extract.self])

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

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Show the capture values, the screenshot gate and the warp tile features of an image.")

        @Argument(help: "The image.") var image: String
        @Flag(help: "Every tile's 19 features, not their means.") var tiles = false
        @Flag(help: "One JSON object instead of text.") var json = false
        @Flag(name: .customLong("exact-warp"), help: "Exact double warp coordinates (debugging only).") var exactWarp = false

        func run() throws {
            guarded {
                let cg = try loadImage(image)
                let capture = CaptureLens.features(cg)
                let gate = ScreenshotLens.gate(cg)
                let (map, geometry) = try WarpLens.tileFeatures(cgImage: cg, quantizeLikeCV2: !exactWarp)
                var means = [Double](repeating: 0, count: map.featureCount)
                for t in 0..<map.count { for (k, v) in map.row(t).enumerated() { means[k] += Double(v) } }
                means = means.map { $0 / Double(max(1, map.count)) }
                if json {
                    var object: [String: Any] = [
                        "image": ["width": cg.width, "height": cg.height, "scored_width": geometry.scoringWidth, "scored_height": geometry.scoringHeight],
                        "capture": Dictionary(uniqueKeysWithValues: zip(CaptureFeatures.names, capture.asVector.map(Double.init))),
                        "screenshot_gate": ["is_screenshot": gate.isScreenshot, "grad_zero": Double(gate.gradZero), "flat_strict": Double(gate.flatStrict), "top_color": Double(gate.topColor)],
                        "warp_feature_means": Dictionary(uniqueKeysWithValues: zip(WarpFeatures.names, means)),
                        "tile_grid": ["rows": map.tileRows, "cols": map.tileCols],
                    ]
                    if tiles { object["tiles"] = map.rowsArray.map { $0.map(Double.init) } }
                    try emitJSON(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: "-")
                    return
                }
                print("\(URL(fileURLWithPath: image).lastPathComponent): \(cg.width)×\(cg.height), scored \(geometry.scoringWidth)×\(geometry.scoringHeight), \(map.tileRows)×\(map.tileCols) tiles")
                print("\ncapture (native, fusion columns 386–394)")
                for (name, value) in zip(CaptureFeatures.names, capture.asVector) { print("  \(name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(value)") }
                print("\nscreenshot gate  \(gate.isScreenshot ? "fires" : "quiet")  grad_zero \(gate.gradZero)  flat_strict \(gate.flatStrict)  top_color \(gate.topColor)")
                print("\nwarp features (mean over \(map.count) tiles)")
                for (name, value) in zip(WarpFeatures.names, means) { print("  \(name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(String(format: "%.6f", value))") }
                if tiles {
                    print("\n" + (["tile"] + WarpFeatures.names).joined(separator: "\t"))
                    for t in 0..<map.count { print(([String(t)] + map.row(t).map { String(format: "%.6g", $0) }).joined(separator: "\t")) }
                }
            }
        }
    }

    struct Tiles: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "tiles", abstract: "Cut a dataset's images into the warp trainer's tile cache (resumable).")
        @Argument(help: "final_mixed's folder (manifest.csv) or a dataset.jsonl.") var dataset: String
        @Option(name: .customLong("sample-per-label"), help: "At most this many images of each label.") var samplePerLabel: Int?
        @Option(help: "The sample's seed.") var seed: UInt64 = 0
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                let engine = TrainingEngine(area: try workArea.resolve(), parent: ShippedBundle.directory)
                let url = datasetURL(dataset)
                let manifest = try engine.manifest(for: url, samplePerLabel: samplePerLabel, seed: seed)
                let cache = engine.tileCache(for: url)
                note("tiles: \(manifest.count) images → \(cache.directory.path)")
                let report = try TileExtractor.extract(manifest, into: cache, note: note)
                print(String(format: "%d images cut (%d tiles), %d already cached, %d skipped, %.1fs → %@", report.images, report.tiles,
                             report.skippedCached, report.failed.count, report.seconds, cache.directory.path))
            }
        }
    }

    struct Patches: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "patches", abstract: "Cut the noiseprint trainer's patches into the work area's cache (CPU only), ahead of `train noiseprint`.")
        @Option(name: .customLong("per-family"), help: "Images per negative family (three quarters train), as `train noiseprint` takes it.") var perFamily: Int = 120
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                var settings = NoiseprintSettings()
                settings.sources.perFamily = perFamily
                let directory = NoiseprintTrainer.cacheDirectory(try workArea.resolve())
                let started = Date()
                let (split, cut) = try NoiseprintTrainer.cut(settings: settings, cacheDirectory: directory, note: note)
                print("camera \(split.cameraTrain.count) train / \(split.cameraTest.count) test; " + settings.sources.negatives.map {
                    "\($0.name) \(split.counts[$0.name]?[1] ?? 0)/\(split.counts[$0.name]?[2] ?? 0)" }.joined(separator: ", "))
                print(String(format: "%d patches a class (cut: camera %d, negatives %d), %@, %.0fs → %@", cut.set.count / 2, cut.cameraCut, cut.negativeCut,
                             cut.hit ? "read from the cache" : "cut and cached", Date().timeIntervalSince(started), cut.cache?.path ?? "no cache"))
                if !cut.failed.isEmpty { print("\(cut.failed.count) images could not be read: " + cut.failed.prefix(5).joined(separator: "; ")) }
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
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                ShippedBundle.registerWeightFolders()
                guard let variant = DinoVariant(rawValue: dino) else { throw VeilGardeFailure.usage("--dino is small, xsmall or xxsmall") }
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
                let extractor = try FeatureExtractor(warpModelURL: ShippedBundle.url(.warpTile), variant: variant)
                note("extract: \(items.count) images → \(storeURL.path)/\(shard)")
                let report = try ShardExtractor.extract(items, shard: shard, store: FeatureStore(directory: storeURL), extractor: extractor, note: note)
                print(String(format: "%@: %d rows written, %d already in the store, %d skipped, %.1fs", report.shard, report.rows, report.skippedKnown,
                             report.failed.count, report.seconds))
            }
        }
    }
}
