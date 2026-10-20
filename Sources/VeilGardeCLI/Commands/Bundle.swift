//
//  Bundle.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde bundle`: what a detector bundle holds. `show` lists its artifacts by role with
//        their hashes, sizes and provenance; `verify` re-hashes every file against the manifest;
//        `diff` names the roles whose bytes differ between two bundles (the shipped one by default),
//        which is what a promote would change.
//

import ArgumentParser
import Foundation
import VeilGarde

struct BundleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bundle", abstract: "Show, verify and diff detector bundles (manifest.json and its artifacts).",
                                                    subcommands: [Show.self, Verify.self, Diff.self])

    static func directory(_ path: String?) -> URL {
        path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? ShippedBundle.directory
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "List a bundle's artifacts and expected weights (default: the shipped bundle).")
        @Argument(help: "A bundle directory.") var path: String?

        func run() throws {
            guarded {
                let bundle = try ModelBundle.load(BundleCommand.directory(path), verify: false)
                print("bundle \(bundle.root.path)  (\(bundle.manifest.format))")
                for a in bundle.manifest.artifacts {
                    print("  " + a.slot.padding(toLength: 22, withPad: " ", startingAt: 0) + a.file.padding(toLength: 36, withPad: " ", startingAt: 0)
                          + "\(a.sha256.prefix(12))  \(ByteCountFormatter.string(fromByteCount: Int64(a.bytes), countStyle: .file))" + (a.frozen ? "  frozen" : "")
                          + (a.source.map { "  ← \($0)" } ?? ""))
                }
                for w in bundle.manifest.weights { print("  weight " + w.file.padding(toLength: 36, withPad: " ", startingAt: 0) + "\(w.sha256.prefix(12))") }
                for e in bundle.manifest.history { print("  \(ISO8601DateFormatter().string(from: e.date))  \(e.kind.rawValue)  \(e.slot)" + (e.note.map { "  \($0)" } ?? "")) }
            }
        }
    }

    struct Verify: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "verify", abstract: "Re-hash every artifact of a bundle against its manifest.")
        @Argument(help: "A bundle directory.") var path: String?

        func run() throws {
            guarded {
                let bundle = try ModelBundle.load(BundleCommand.directory(path))
                print("ok  \(bundle.manifest.artifacts.count) artifacts verified in \(bundle.root.path)")
            }
        }
    }

    struct Diff: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "diff", abstract: "Name the roles whose bytes differ between two bundles.")
        @Argument(help: "The bundle to compare.") var path: String
        @Argument(help: "The bundle to compare against (default: the shipped bundle).") var base: String?

        func run() throws {
            guarded {
                let a = try ModelBundle.load(BundleCommand.directory(base), verify: false).manifest
                let b = try ModelBundle.load(BundleCommand.directory(path), verify: false).manifest
                let slots = Set(a.artifacts.map(\.slot)).union(b.artifacts.map(\.slot)).sorted()
                var changed = 0
                for slot in slots {
                    let x = a.artifact(slot: slot), y = b.artifact(slot: slot)
                    guard x?.sha256 != y?.sha256 else { continue }
                    changed += 1
                    print("  " + slot.padding(toLength: 22, withPad: " ", startingAt: 0) + "\(x?.sha256.prefix(12) ?? "absent") → \(y?.sha256.prefix(12) ?? "absent")")
                }
                print(changed == 0 ? "no artifact differs" : "\(changed) role(s) differ")
            }
        }
    }
}
