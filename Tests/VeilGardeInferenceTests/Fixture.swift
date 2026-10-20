//
//  Fixture.swift
//  VeilGardeInferenceTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Paths the Inference tests read by repo path: Garde's goldens (the parity crops and the JSON
//        Garde's headless app wrote for them on 2026-10-19), and whether the neural weights are present.
//

import Foundation
import VeilGardeInference

enum Fixture {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "Tests" { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent()
    }()

    static func garde(_ name: String) -> URL { repoRoot.appendingPathComponent("Tests/VeilGardeInferenceTests/Fixtures/garde/\(name)") }

    /// The parity fixtures too large for the repo (dino_parity.safetensors is 1.8 MB), in the work
    /// area's parity/; VEILGARDE_PARITY_DIR names another folder.
    static let parityDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VEILGARDE_PARITY_DIR"]
        ?? WorkArea.resolve()?.parity.path ?? "parity")

    static var weightsPresent: Bool {
        ShippedBundle.registerWeightFolders()
        return WeightLocator.shared.url(.dinov2Small) != nil && WeightLocator.shared.url(.noiseprint) != nil
    }
}
