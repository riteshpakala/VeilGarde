//
//  SealMark.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde seal make|detect|records|resizing-test`: the Burgundy Seal from the terminal.
//        `make` seals a picture and keeps its seal (with --interlace, also writes a copy that carries
//        the seal's id); `detect` says which stored seal a found picture holds (the exit code with
//        --require); `records` lists a store; `resizing-test` seals a picture and detects it again at
//        50, 75, 150 and 200 %.
//  PIN:  The store is the folder --store names, else VEILGARDE_SEAL_STORE, else none (make then prints
//        the seal and keeps nothing; detect has nothing to search). Point it at an app's folder to see
//        what the app sealed, e.g. Craft's agent-support/VeilAgent/seals. The seal is under
//        measurement: an acceptance run, held to bars fixed before it runs, decides its thresholds.
//

import ArgumentParser
import Foundation
import VeilGarde

/// The store a seal command uses, and the key.
struct SealStoreOptions: ParsableArguments {
    @Option(help: "The seal store's folder (default: VEILGARDE_SEAL_STORE).") var store: String?
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

/// The seal's own failures as the CLI's exit codes.
func sealFailure(_ error: Error) -> Error {
    switch error {
    case let failure as SealFailure:
        switch failure {
        case .alreadyInterlaced: return VeilGardeFailure.exists(failure.description)
        case .noAnchors, .tooSmallToInterlace, .messageNotYet: return VeilGardeFailure.data(failure.description)
        }
    case let failure as SealStoreError:
        return VeilGardeFailure.data(failure.localizedDescription)
    default:
        return error
    }
}

extension SealCommand {
    struct Make: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "make", abstract: "Seal a picture: keep its signature (anchors, paths, warp residual) in the store.",
            discussion: "With --interlace, also write a copy that carries the seal's id in its pixels.")

        @Argument(help: "The picture to seal.") var image: String
        @Option(help: "Who or what the picture is sealed as.") var label: String?
        @Flag(help: "Also hide the seal's id in a copy (needs about 1 MP).") var interlace = false
        @Option(help: "Your own words to hide instead (not yet: the anchor interlace is still being measured).") var message: String?
        @Option(help: "Write the interlaced copy here (PNG).") var out: String?
        @Flag(help: "Print the seal as JSON.") var json = false
        @OptionGroup var storeOptions: SealStoreOptions

        func run() throws {
            guarded {
                let store = try storeOptions.open()
                if store == nil { note("make: no store (--store or VEILGARDE_SEAL_STORE): the seal is printed, not kept") }
                let mode: Interlace? = message.map { .message($0) } ?? (interlace ? .signature : nil)
                if mode != nil, out == nil { throw VeilGardeFailure.usage("--interlace writes a copy: pass --out") }
                let sealed: SealedPicture
                do {
                    sealed = try BurgundySeal.seal(contentsOf: datasetURL(image), label: label, store: store, key: try storeOptions.key(),
                                                   interlace: mode, progress: { note("make: " + $0.rawValue) })
                } catch {
                    throw sealFailure(error)
                }
                if let copy = sealed.interlaced, let out { try copy.write(to: datasetURL(out)) }
                let r = sealed.record
                if json {
                    try emitJSON(try JSONCoding.prettyEncoder().encode(r), to: "-")
                } else {
                    print("\(sealed.existing ? "already sealed" : "sealed") \(r.id.hex)\(r.label.map { " “\($0)”" } ?? "") · \(r.anchors.count) anchors · "
                        + "\(r.paths.count) paths, \(r.hopCount) hops" + (r.interlace.map { " · interlaced (\($0.carrier)) → \(out ?? "")" } ?? ""))
                }
                if let store { note("seal: \(store.directory.path)") }
            }
        }
    }

    struct Detect: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "detect", abstract: "Say which stored seal a found picture holds: sealed, interlace only, content mismatch, unknown seal or none.",
            discussion: "With --require the exit code is the verdict: 0 when sealed, 1 otherwise.")

        @Argument(help: "The picture to read.") var image: String
        @Flag(help: "Print the detection as JSON.") var json = false
        @Flag(help: "Exit 1 unless the verdict is sealed.") var require = false
        @OptionGroup var storeOptions: SealStoreOptions

        func run() throws {
            guarded {
                let d = try BurgundySeal.detect(contentsOf: datasetURL(image), store: try storeOptions.open(), key: try storeOptions.key())
                if json { try emitJSON(try JSONCoding.prettyEncoder().encode(d), to: "-") } else { print(d.summary) }
                note(String(format: "detect: %d anchors against %d seals, %.1f s", d.anchors, d.seals, d.seconds))
                if require, d.verdict != .sealed { throw ExitCode(1) }
            }
        }
    }

    struct Records: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "records", abstract: "List the seals a store holds: id, label, size, when, anchors.")
        @Flag(help: "JSON instead of text.") var json = false
        @OptionGroup var storeOptions: SealStoreOptions

        func run() throws {
            guarded {
                guard let store = try storeOptions.open() else { throw VeilGardeFailure.usage("no store: pass --store or set VEILGARDE_SEAL_STORE") }
                let records = try store.records()
                if json { try emitJSON(try JSONCoding.prettyEncoder().encode(records), to: "-"); return }
                let iso = ISO8601DateFormatter()
                for r in records {
                    print("\(r.id.hex)  \(r.image.width)×\(r.image.height)  \(iso.string(from: r.createdAt))  \(r.anchors.count) anchors  "
                        + "\(r.interlace == nil ? "-" : "interlaced")  \(r.label ?? "-")  \(r.image.name ?? "")")
                }
                note("\(records.count) seals in \(store.directory.path)")
            }
        }
    }

    struct ResizingTest: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "resizing-test", abstract: "Seal a picture in a scratch store and detect it again resized to 50, 75, 150 and 200 %.")

        @Argument(help: "The picture.") var image: String
        @Option(help: "Scales in percent, comma-separated.") var scales: String = "50,75,150,200"

        func run() throws {
            guarded {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("seal-resizing-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let store = try SealStore(directory: folder)
                let url = datasetURL(image)
                let sealed = try BurgundySeal.seal(contentsOf: url, label: "resizing-test", store: store)
                print("sealed \(sealed.record.id.hex) · \(sealed.record.anchors.count) anchors · \(sealed.record.paths.count) paths")
                let cg = try ImageDecoding.cgImage(contentsOf: url)
                var held = 0, tried = 0
                for percent in scales.split(separator: ",").compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                    guard let scaled = ImageCodec.resized(cg, by: Double(percent) / 100) else { continue }
                    let d = try BurgundySeal.detect(scaled, store: store)
                    tried += 1
                    if d.verdict == .sealed { held += 1 }
                    let m = d.match
                    print(String(format: "%4d %%  %@  inliers %d · hops %d/%d · coverage %.0f%% · scale %.2f", percent, d.verdict.words.padding(toLength: 16, withPad: " ", startingAt: 0),
                                 m?.inliers ?? 0, m?.retraced ?? 0, m?.possible ?? 0, 100 * (m?.coverage ?? 0), m?.scale ?? 0))
                }
                print("\(held) of \(tried) scales sealed")
            }
        }
    }
}

extension SealCommand {
    struct Render: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "render", abstract: "Draw a seal's digest or a detection's graphic (the Burgundy Seal).", subcommands: [SealPage.self, DetectionPage.self])

        struct SealPage: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "seal", abstract: "A seal's digest: the picture with its anchors and paths, and its wax seal.")
            @Argument(help: "A picture to seal (kept when there is a store), or a stored seal's id.") var source: String
            @Option(help: "The picture, when the source is an id.") var picture: String?
            @Option(help: "Who or what the picture is sealed as.") var label: String?
            @Option(help: "Write the PNG here.") var out: String
            @OptionGroup var storeOptions: SealStoreOptions

            func run() throws {
                guarded {
                    let store = try storeOptions.open()
                    if let id = SealID(hex: source), !FileManager.default.fileExists(atPath: datasetURL(source).path) {
                        guard let store else { throw VeilGardeFailure.usage("an id needs --store (or VEILGARDE_SEAL_STORE)") }
                        guard let record = try store.record(for: id) else { throw VeilGardeFailure.missing("the store holds no seal \(id.hex)") }
                        let cg = try picture.map { try ImageDecoding.cgImage(contentsOf: datasetURL($0)) }
                        try BurgundySeal.digest(record, picture: cg).write(to: datasetURL(out))
                    } else {
                        let url = datasetURL(source)
                        let sealed: SealedPicture
                        do { sealed = try BurgundySeal.seal(contentsOf: url, label: label, store: store, key: try storeOptions.key()) } catch { throw sealFailure(error) }
                        try BurgundySeal.digest(sealed.record, picture: try ImageDecoding.cgImage(contentsOf: url)).write(to: datasetURL(out))
                        print("\(sealed.existing ? "already sealed" : "sealed") \(sealed.record.id.hex) → \(out)")
                    }
                }
            }
        }

        struct DetectionPage: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "detection", abstract: "Detect a found picture and draw what was found over it.")
            @Argument(help: "The found picture.") var picture: String
            @Option(help: "Write the PNG here.") var out: String
            @OptionGroup var storeOptions: SealStoreOptions

            func run() throws {
                guarded {
                    let url = datasetURL(picture)
                    let d = try BurgundySeal.detect(contentsOf: url, store: try storeOptions.open(), key: try storeOptions.key())
                    try BurgundySeal.graphic(d, picture: try ImageDecoding.cgImage(contentsOf: url)).write(to: datasetURL(out))
                    print(d.summary)
                }
            }
        }
    }
}
