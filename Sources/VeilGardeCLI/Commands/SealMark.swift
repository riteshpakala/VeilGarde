//
//  SealMark.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde seal embed|detect|render|records`: the pixel mark (vgm1) from the terminal.
//        `embed` writes a marked PNG and keeps its record; `detect` reads a mark blind and says whose
//        it is (the exit code with --require); `render` draws a record's or a detection's digest, or a
//        detection's overlay; `records` lists a store.
//  PIN:  The store is the folder --store names, else VEILGARDE_SEAL_STORE, else none (embed then
//        prints the record and keeps nothing; detect cannot say whose an id is). Point it at an app's
//        folder to see what the app recorded, e.g. Craft's agent-support/VeilAgent/signatures. The mark
//        is under measurement: an acceptance run, held to bars fixed before it runs, decides whether it stays.
//

import ArgumentParser
import Foundation
import VeilGarde

/// The store a mark command uses, and the key.
struct MarkStoreOptions: ParsableArguments {
    @Option(help: "The signature store's folder (default: VEILGARDE_SEAL_STORE).") var store: String?
    @Option(name: .customLong("key-file"), help: "A key file: 32 bytes or 64 hex digits (default: the public key).") var keyFile: String?

    func open() throws -> SealStore? {
        guard let path = store ?? ProcessInfo.processInfo.environment["VEILGARDE_SEAL_STORE"].flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
        do {
            return try SealStore(directory: datasetURL(path))
        } catch let error as SealStoreError {
            throw VeilGardeFailure.configuration(error.localizedDescription)
        }
    }

    func key() throws -> SealKey { try keyFile.map { try SealKey(contentsOf: datasetURL($0)) } ?? .default }
}

/// The mark's own failures as the CLI's exit codes.
func markFailure(_ error: Error) -> Error {
    switch error {
    case let failure as MarkFailure:
        switch failure {
        case .alreadyMarked, .idTaken: return VeilGardeFailure.exists(failure.description)
        case .tooSmall: return VeilGardeFailure.data(failure.description)
        }
    case let failure as SealStoreError:
        return VeilGardeFailure.data(failure.localizedDescription)
    default:
        return error
    }
}

extension SealCommand {
    struct Embed: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "embed", abstract: "Mark an image with an id in its pixels (vgm1) and keep its record in the store.",
            discussion: "Writes a PNG. The mark is under measurement: do not rely on it until its acceptance run passes.")
        @Argument(help: "The image to mark.") var image: String
        @Option(help: "Write the marked PNG here.") var out: String
        @Option(help: "The id, 16 hex digits (default: one the store does not hold).") var id: String?
        @Option(help: "Who or what the image is recorded as.") var label: String?
        @Option(help: "The most a pixel's luma may move, in levels.") var bound: Int?
        @Option(help: "Optimiser steps.") var steps: Int?
        @Option(help: "Also write the record's digest PNG here.") var digest: String?
        @Flag(help: "Mark an image that already carries a mark.") var force = false
        @Flag(help: "Print the record as JSON.") var json = false
        @OptionGroup var storeOptions: MarkStoreOptions

        func run() throws {
            guarded {
                let store = try storeOptions.open()
                var settings = MarkSettings.default
                if let bound { settings.bound = bound }
                if let steps { settings.steps = steps }
                settings.force = force
                let chosen = try id.map { hex -> SealID in
                    guard let parsed = SealID(hex: hex) else { throw VeilGardeFailure.usage("--id is 16 hex digits, not \(hex)") }
                    return parsed
                }
                if store == nil { note("embed: no store (--store or VEILGARDE_SEAL_STORE): the record is printed, not kept") }
                let marked: SealedImage
                do {
                    marked = try BurgundySeal.embed(contentsOf: datasetURL(image), id: chosen, label: label, store: store, key: try storeOptions.key(),
                                                 settings: settings, progress: { note("embed: " + $0.line) })
                } catch {
                    throw markFailure(error)
                }
                try marked.png.write(to: datasetURL(out))
                if let digest { try BurgundySeal.digest(marked.record).write(to: datasetURL(digest)) }
                let r = marked.report
                if json {
                    try emitJSON(try JSONCoding.prettyEncoder().encode(marked.record), to: "-")
                } else {
                    print(String(format: "marked %@ → %@ · PSNR %.1f dB · L∞ %d · %@ · %d steps, %d repairs · %.0f s", marked.record.id.hex, out, r.psnr, r.linf,
                                 r.verified ? "verified" : "NOT verified", r.steps, r.repairs, r.seconds))
                }
                if let store { note("record: \(store.directory.path)") }
                if !r.verified { note("embed: the marked PNG did not read back as its id; the record is kept, and detection may miss it") }
            }
        }
    }

    struct Detect: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "detect", abstract: "Read a pixel mark blind and say whose it is: marked, content mismatch, unknown id, passive match or none.",
            discussion: "With --require the exit code is the verdict: 0 when marked, 1 otherwise.")
        @Argument(help: "The image to read.") var image: String
        @Option(help: "Also write the overlay PNG here.") var overlay: String?
        @Option(help: "The overlay's tint: auto, mark or passive.") var layer: String = OverlayLayer.auto.rawValue
        @Option(help: "Also write the detection's digest PNG here.") var digest: String?
        @Flag(help: "Print the detection as JSON.") var json = false
        @Flag(help: "Keep the per-tile maps and soft bits in the JSON.") var maps = false
        @Flag(help: "Exit 1 unless the verdict is marked.") var require = false
        @OptionGroup var storeOptions: MarkStoreOptions

        func run() throws {
            guarded {
                guard let tint = OverlayLayer(rawValue: layer) else { throw VeilGardeFailure.usage("--layer is auto, mark or passive") }
                let url = datasetURL(image)
                let d = try BurgundySeal.detect(contentsOf: url, store: try storeOptions.open(), key: try storeOptions.key())
                if let overlay { try BurgundySeal.overlay(d, queryContentsOf: url, layer: tint).write(to: datasetURL(overlay)) }
                if let digest { try BurgundySeal.digest(d).write(to: datasetURL(digest)) }
                if json { try emitJSON(try JSONCoding.prettyEncoder().encode(maps ? d : d.withoutMaps), to: "-") } else { print(d.summary) }
                note(String(format: "detect: %d tiles, %d reads, %.1f s", d.reading.tiles, d.reading.reads, d.seconds))
                if require, d.verdict != .marked { throw ExitCode(1) }
            }
        }
    }

    struct Render: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "render", abstract: "Draw a record's or a detection's digest, or a detection's overlay on its image.",
            subcommands: [Digest.self, Overlay.self])

        struct Digest: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "digest", abstract: "A 640 × 800 digest of a record or a detection (`detect --json --maps`).")
            @Argument(help: "A record's or a detection's JSON file, or a stored id with --store.") var source: String
            @Option(help: "Write the PNG here.") var out: String
            @OptionGroup var storeOptions: MarkStoreOptions

            func run() throws {
                guarded {
                    let png: Data
                    if let id = SealID(hex: source), !FileManager.default.fileExists(atPath: datasetURL(source).path) {
                        guard let store = try storeOptions.open() else { throw VeilGardeFailure.usage("an id needs --store (or VEILGARDE_SEAL_STORE)") }
                        guard let record = try store.record(for: id) else { throw VeilGardeFailure.missing("the store holds no id \(id.hex)") }
                        png = try BurgundySeal.digest(record)
                    } else {
                        let data = try Data(contentsOf: datasetURL(source))
                        if let record = try? JSONCoding.decoder().decode(SealRecord.self, from: data) {
                            png = try BurgundySeal.digest(record)
                        } else {
                            png = try BurgundySeal.digest(try JSONCoding.decoder().decode(SealDetection.self, from: data))
                        }
                    }
                    try png.write(to: datasetURL(out))
                }
            }
        }

        struct Overlay: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "overlay", abstract: "A detection (`detect --json --maps`) drawn over the image it read.")
            @Argument(help: "The detection's JSON file.") var detection: String
            @Argument(help: "The image it read.") var image: String
            @Option(help: "Write the PNG here.") var out: String
            @Option(help: "The tint: auto, mark or passive.") var layer: String = OverlayLayer.auto.rawValue

            func run() throws {
                guarded {
                    guard let tint = OverlayLayer(rawValue: layer) else { throw VeilGardeFailure.usage("--layer is auto, mark or passive") }
                    let d = try JSONCoding.decoder().decode(SealDetection.self, from: try Data(contentsOf: datasetURL(detection)))
                    try BurgundySeal.overlay(d, queryContentsOf: datasetURL(image), layer: tint).write(to: datasetURL(out))
                }
            }
        }
    }

    struct Records: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "records", abstract: "List the marks a signature store holds: id, label, size, when, verified.")
        @Flag(help: "JSON instead of text.") var json = false
        @OptionGroup var storeOptions: MarkStoreOptions

        func run() throws {
            guarded {
                guard let store = try storeOptions.open() else { throw VeilGardeFailure.usage("no store: pass --store or set VEILGARDE_SEAL_STORE") }
                let records = try store.records()
                if json { try emitJSON(try JSONCoding.prettyEncoder().encode(records), to: "-"); return }
                let iso = ISO8601DateFormatter()
                for r in records {
                    print("\(r.id.hex)  \(r.width)×\(r.height)  \(iso.string(from: r.createdAt))  \(r.report.verified ? "verified" : "unverified")  \(r.label ?? "-")  \(r.sourceName ?? "")")
                }
                note("\(records.count) records in \(store.directory.path)")
            }
        }
    }
}
