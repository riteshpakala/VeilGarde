//
//  Fixture.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Paths the Core tests read: their committed fixtures (written once from the Python
//        reference) and the shipped bundle's resources, both by repo path.
//

import Foundation
import VeilGardeCore

enum Fixture {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "Tests" { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent()
    }()

    static let resources = repoRoot.appendingPathComponent("Sources/VeilGardeInference/Resources")

    static func resource(_ name: String) -> URL { resources.appendingPathComponent(name) }

    static func url(_ name: String) -> URL { repoRoot.appendingPathComponent("Tests/VeilGardeCoreTests/Fixtures/\(name)") }

    static func json(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url(name))) as! [String: Any]
    }

    /// The work area's feature store, when this Mac has it (the Store suite reads one small shard
    /// from it); VEILGARDE_SEED_STORE names another.
    static let seedStore = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VEILGARDE_SEED_STORE"]
        ?? WorkArea.resolve()?.shards.path ?? "store/shards")
}

func floats(_ any: Any?) -> [Float] { (any as? [NSNumber])?.map { $0.floatValue } ?? [] }
func float(_ any: Any?) -> Float? { (any as? NSNumber)?.floatValue }
