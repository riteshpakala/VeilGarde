//
//  Route.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde route <image>`: the full detector. The router picks the domain, the base expert
//        runs (camera: the fusion head; screenshot: the content head), and the specialists, the
//        frame seam and the semantic chain compound on it. Prints the domain, the verdict, the
//        base expert's own P(AI), the capture signature and the specialist stack, or the schema-v3
//        JSON with --json. `batch` routes a manifest of images into a JSONL of results.
//  PIN:  --json writes times_sec [], device "route", route = the domain.
//

import ArgumentParser
import Foundation
import VeilGarde

struct RouteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "route", abstract: "Run the full detector: route, base expert, specialist stack, mechanisms.")

    @Argument(help: "The image.") var image: String
    @OptionGroup var route: RouteOptions
    @Option(help: "Skip domain detection: camera or screenshot.") var hint: String?
    @Flag(help: "The schema-v3 JSON on stdout.") var json = false
    @Flag(help: "Run MLX on the CPU.") var cpu = false

    func run() throws {
        guarded {
            let config = try route.config()
            let domainHint = try parseHint(hint)
            let cg = try loadImage(image)
            let routed = try LensRuntime.withDevice(cpu: cpu) { try Detector.shared.detect(cgImage: cg, config: config, hint: domainHint) }
            let r = routed.result
            if json {
                try emitJSON(try ResultJSON.encode(r, times: [], device: "route", route: routed.domain.rawValue), to: "-")
                return
            }
            let capture = r.captureSignature.map { !$0.valid ? "invalid" : ($0.present ? "present" : "absent") } ?? "n/a"
            let stack = (r.specialists ?? []).map { String(format: "%@(p=%.2f w=%.1f→%@)", $0.name, $0.pAI, $0.weight, $0.verdict) }.joined(separator: " + ")
            print(String(format: "route  domain=%@  verdict=%@  p=%.4f  base=%@ %.4f  capture=%@\n  stack: %@",
                         routed.domain.rawValue, r.prediction, r.p, r.scorer, r.routeDiagnostics?.baseP ?? r.p, capture, stack))
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
