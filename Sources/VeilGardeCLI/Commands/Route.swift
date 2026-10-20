//
//  Route.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde route <image>`: the full detector. The router picks the domain, the base expert
//        runs (camera: warp lens + fusion; screenshot: the content head), and the specialists,
//        the frame seam and the semantic chain compound on it. Prints the domain, the verdict and
//        the specialist stack, the full patch map with --map, or the schema-v2 JSON with --json.
//        Replaces Garde's headless --route / --route-json.
//  PIN:  --json writes Garde's route bytes: times_sec [], device "route", route = the domain.
//

import ArgumentParser
import Foundation
import VeilGarde

struct RouteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "route", abstract: "Run the full detector: route, base expert, specialist stack, mechanisms.")

    @Argument(help: "The image.") var image: String
    @OptionGroup var route: RouteOptions
    @Option(help: "Skip domain detection: camera or screenshot.") var hint: String?
    @Flag(help: "The schema-v2 JSON on stdout.") var json = false
    @Flag(help: "Print the patch map and every verdict, as `score` does.") var map = false
    @Flag(name: .customLong("no-color"), help: "No terminal colours.") var noColor = false
    @Flag(help: "Run MLX on the CPU.") var cpu = false

    func run() throws {
        guarded {
            let config = try route.config()
            let domainHint = try parseHint(hint)
            let cg = try loadImage(image)
            let ((routed), seconds) = try LensRuntime.withDevice(cpu: cpu) { try timed { try Detector.shared.detect(cgImage: cg, config: config, hint: domainHint) } }
            let r = routed.result
            if json {
                try emitJSON(try ResultJSON.encode(r, times: [], device: "route", route: routed.domain.rawValue), to: "-")
                return
            }
            if map {
                print(PatchMap.render(r, imagePath: image, model: "domain \(routed.domain.rawValue)", times: [seconds], device: LensRuntime.deviceName(cpu: cpu),
                                      color: !noColor && isatty(STDOUT_FILENO) == 1), terminator: "")
                return
            }
            let stack = (r.specialists ?? []).map { String(format: "%@(p=%.2f w=%.1f→%@)", $0.name, $0.pAI, $0.weight, $0.verdict) }.joined(separator: " + ")
            print(String(format: "route  domain=%@  verdict=%@  p=%.4f  majority=%@:%@  tile-map=%@\n  stack: %@",
                         routed.domain.rawValue, r.weightedPrediction, r.weightedScore, PatchMap.sourceLabel(r.majoritySource), r.majorityPrediction,
                         PatchMap.sourceLabel(r.tileMapSource), stack))
        }
    }
}

struct FuseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fuse", abstract: "The camera base expert alone: the warp lens and the fusion head, no specialists.")

    @Argument(help: "The image.") var image: String
    @OptionGroup var detection: DetectionOptions
    @Option(help: "DINOv2 weights: small, xsmall or xxsmall.") var dino: String = DinoVariant.small.rawValue
    @Option(help: "Write the schema-v2 JSON to this path, or - for stdout only.") var json: String?
    @Flag(name: .customLong("no-color"), help: "No terminal colours.") var noColor = false

    func run() throws {
        guarded {
            var config = try detection.config()
            guard let variant = DinoVariant(rawValue: dino) else { throw VeilGardeFailure.usage("--dino must be small, xsmall or xxsmall") }
            config.dinoVariant = variant
            config.useFusion = true
            let cg = try loadImage(image)
            let (r, seconds) = try LensRuntime.withDevice(cpu: detection.cpu) { try timed { try Fusion.run(cgImage: cg, config: config) } }
            let device = LensRuntime.deviceName(cpu: detection.cpu)
            if let json {
                try emitJSON(try ResultJSON.encode(r, times: [seconds], device: device), to: json)
                if json == "-" { return }
            }
            print(PatchMap.render(r, imagePath: image, model: "fusion", times: [seconds], device: device, color: !noColor && isatty(STDOUT_FILENO) == 1), terminator: "")
        }
    }
}

struct BatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "batch", abstract: "Route a JSONL manifest of {id, path, hint} rows, in order, into a JSONL of results.")

    @Argument(help: "The manifest: one {\"id\", \"path\", \"hint\"} object per line.") var input: String
    @Argument(help: "The output JSONL; it must not exist.") var output: String
    @OptionGroup var route: RouteOptions

    func run() throws {
        guarded {
            let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath).standardizedFileURL
            let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL
            guard inputURL.resolvingSymlinksInPath() != outputURL.resolvingSymlinksInPath() else { throw VeilGardeFailure.usage("the input and output paths must differ") }
            guard !FileManager.default.fileExists(atPath: outputURL.path) else { throw VeilGardeFailure.exists("refusing to overwrite \(outputURL.path)") }
            let config = try route.config()
            // The whole manifest validates before any inference.
            let items = try RouteBatch.parse(Data(contentsOf: inputURL))
            let temporary = outputURL.deletingLastPathComponent().appendingPathComponent(".\(outputURL.lastPathComponent).tmp-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw VeilGardeFailure.internalError("cannot create \(temporary.path)") }
            do {
                let handle = try FileHandle(forWritingTo: temporary)
                for (index, item) in items.enumerated() {
                    defer { LensRuntime.releaseMemory() }
                    let cg = try loadImage(item.path)
                    let routed = try Detector.shared.detect(cgImage: cg, config: config, hint: item.hint)
                    var line = Data("{\"id\":".utf8)
                    line.append(try JSONEncoder().encode(item.id))
                    line.append(Data(",\"result\":".utf8))
                    line.append(try ResultJSON.encode(routed.result, times: [], device: "route-batch", route: routed.domain.rawValue))
                    line.append(Data("}\n".utf8))
                    try handle.write(contentsOf: line)
                    if (index + 1).isMultiple(of: 64) { try handle.synchronize(); note("batch: \(index + 1)/\(items.count)") }
                }
                try handle.synchronize()
                try handle.close()
                try FileManager.default.moveItem(at: temporary, to: outputURL)
                note("batch: \(items.count) results → \(outputURL.path)")
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
    }
}
