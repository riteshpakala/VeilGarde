//
//  Fixture.swift
//  VeilGardeInferenceTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Paths the Inference tests read by repo path: the two parity crops and VeilGarde's own route
//        goldens for them, and whether the DINOv2 weights are present.
//

import Foundation
import VeilGardeInference

enum Fixture {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "Tests" { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent()
    }()

    static func crop(_ name: String) -> URL { repoRoot.appendingPathComponent("Tests/VeilGardeInferenceTests/Fixtures/crops/\(name)") }

    /// The parity fixtures too large for the repo (dino_parity.safetensors is 1.8 MB), in the work
    /// area's parity/; VEILGARDE_PARITY_DIR names another folder.
    static let parityDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VEILGARDE_PARITY_DIR"]
        ?? WorkArea.resolve()?.parity.path ?? "parity")

    static var weightsPresent: Bool {
        ShippedBundle.registerWeightFolders()
        return WeightLocator.shared.url(.dinov2Small) != nil
    }
}
