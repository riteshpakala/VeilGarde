//
//  Fixture.swift
//  VeilGardeLensTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Paths the Lens tests read by repo path: their own fixtures (the CLIP parity file), and the
//        shipped resources.
//

import Foundation

enum Fixture {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "Tests" { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent()
    }()

    static func url(_ name: String) -> URL { repoRoot.appendingPathComponent("Tests/VeilGardeLensTests/Fixtures/\(name)") }
    static func resource(_ name: String) -> URL { repoRoot.appendingPathComponent("Sources/VeilGardeInference/Resources/\(name)") }
}
