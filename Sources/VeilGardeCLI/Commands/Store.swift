//
//  Store.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde store migrate`: rewrites a folder of older shards as veilgarde-feature-shard-v1
//        shards in a new folder, the same rows and the three columns the store keeps, and checks
//        each shard after it is written.
//  PIN:  The old folder is only read; everything an old shard carried beyond the three columns stays
//        there. Exit 65 when a shard does not migrate whole.
//

import ArgumentParser
import Foundation
import VeilGarde

struct StoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "store", abstract: "Manage the features-only store: migrate older shards to the current format.",
        subcommands: [Migrate.self])

    struct Migrate: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "migrate", abstract: "Rewrite older shards as v1 shards in a new folder: the same rows, the three kept columns, each checked.",
            discussion: "The old folder is read, never written. Move it aside first, then migrate into the store's folder.")
        @Option(help: "The folder of older shards (read only).") var from: String
        @Option(help: "The new folder (no shard of the same name may exist there).") var to: String
        @Option(help: "Write the per-shard report here too (`-` for stdout).") var json: String?

        func run() throws {
            guarded {
                let reports = try StoreMigration.migrate(from: datasetURL(from), to: datasetURL(to), note: note)
                if let json { try emitJSON(try JSONCoding.prettyEncoder().encode(reports), to: json) }
                let left = Set(reports.flatMap(\.left)).sorted()
                print("migrate: \(reports.count) shards, \(reports.map(\.rowsIn).reduce(0, +)) rows in, \(reports.map(\.rowsOut).reduce(0, +)) rows out; "
                      + "every column's bytes equal: \(reports.allSatisfy(\.equal) ? "yes" : "NO")")
                print("left in the old folder: " + (left.isEmpty ? "nothing" : left.joined(separator: ", ")))
                if !reports.allSatisfy(\.equal) { throw ExitCode(FailureCode.data.rawValue) }
            }
        }
    }
}
