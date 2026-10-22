//
//  Route.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde route <image>`: the full detector, Decode → Shared Signals → Stack → Revisions →
//        Result. Prints the verdict, then every member of the stack with its own P(AI) and verdict,
//        then every revision and what it did, or the schema-v1 JSON with --json. `batch` runs a
//        manifest of images into a JSONL of results.
//  PIN:  --json writes times_sec [] and device "route"; batch writes device "route-batch".
//

import ArgumentParser
import Foundation
import VeilGarde

struct RouteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "route", abstract: "Run the full detector: every member of the stack, then the revisions, one verdict.")

    @Argument(help: "The image.") var image: String
    @OptionGroup var route: RouteOptions
    @Flag(help: "The schema-v1 JSON on stdout.") var json = false
    @Flag(help: "Run MLX on the CPU.") var cpu = false

    func run() throws {
        guarded {
            let config = try route.config()
            let cg = try loadImage(image)
            let r = try LensRuntime.withDevice(cpu: cpu) { try Detector.detect(cgImage: cg, config: config) }
            if json {
                try emitJSON(try ResultJSON.encode(r, times: [], device: "route"), to: "-")
                return
            }
            print(Self.text(r))
        }
    }

    /// The result as lines: the verdict, the stack, the revisions.
    static func text(_ r: InferenceResult) -> String {
        func number(_ v: Float?) -> String { v.map { String(format: "%.4f", $0) } ?? "—" }
        func scalars(_ fields: [Field]) -> String {
            fields.compactMap { f -> String? in
                switch f.value {
                case .number(let v): return "\(f.key)=" + String(format: "%.4g", v)
                case .flag(let v): return "\(f.key)=\(v)"
                case .text(let v): return "\(f.key)=\(v)"
                case .map(let m): return "\(f.key)=" + m.sorted { $0.key < $1.key }.map { "\($0.key):" + String(format: "%.3g", $0.value) }.joined(separator: ",")
                case .grid, .absent: return nil
                }
            }.joined(separator: "  ")
        }
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
        var lines = [String(format: "verdict  %@  p=%.4f  (%.2f ± %.2f)", r.prediction, r.p, r.threshold, r.band), "stack"]
        for m in r.stack { lines.append("  " + pad(m.name, 16) + pad("p=" + number(m.p), 10) + "  " + pad(m.verdict, 13) + scalars(m.fields)) }
        lines.append("revisions")
        for v in r.revisions {
            lines.append("  " + pad(v.name, 16) + pad(v.applied ? "applied" : "skipped", 9) + " " + pad("p=" + number(v.p), 10) + "  " + pad(v.prediction, 13) + scalars(v.fields))
        }
        return lines.joined(separator: "\n")
    }
}

struct BatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "batch", abstract: "Run a JSONL manifest of {id, path} rows, in order, into a JSONL of results.")

    @Argument(help: "The manifest: one {\"id\", \"path\"} object per line.") var input: String
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
                    let result = try Detector.detect(cgImage: cg, config: config)
                    var line = Data("{\"id\":".utf8)
                    line.append(try JSONEncoder().encode(item.id))
                    line.append(Data(",\"result\":".utf8))
                    line.append(try ResultJSON.encode(result, times: [], device: "route-batch"))
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
