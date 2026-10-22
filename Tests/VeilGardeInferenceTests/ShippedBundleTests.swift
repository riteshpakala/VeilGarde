//
//  ShippedBundleTests.swift
//  VeilGardeInferenceTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The shipped bundle verifies, holds the camera head and the combiner trained on 2026-10-21
//        and the six heads, the combiner pools members the stack holds, and the detector's defaults
//        point into it at the camera member's operating point.
//

import Foundation
import Testing
@testable import VeilGardeInference

@Suite("Shipped bundle")
struct ShippedBundleTests {
    @Test("the shipped bundle verifies and the defaults point into it")
    func defaults() throws {
        let bundle = try ShippedBundle.verified()
        #expect(bundle.manifest.artifacts.count == 8 && bundle.manifest.weights.count == 3)
        #expect(bundle.manifest.artifact(.camera)?.sha256 == "b142e661c609070a7838fb015ae47a8b9ccce2ab1d539c3dac29afadc48b8f9e")
        #expect(bundle.manifest.artifact(.combiner)?.file == "stack_combiner.json")
        let config = InferenceConfig()
        #expect(config.bundle.isShipped && config.decision == .camera && config.dinoVariant == .small && config.semanticResponsibility == .control)
        #expect(config.bundle.url(.camera)?.lastPathComponent == "camera.xgb.json")
        #expect(config.bundle.hashes.artifacts.count == 8 && config.bundle.provenance["camera_sha256"] != nil)
    }

    @Test("the shipped combiner pools members the shipped pipeline holds")
    func combiner() throws {
        let c = try #require(HeadRegistry.shared.combiner(in: .shipped))
        let names = Pipeline.v1.stack.members.map(\.name)
        #expect(c.evidenceMembers == ["art", "blur", "human"] && c.evidenceMembers.allSatisfy(names.contains))
        #expect(names.contains("camera") && names.contains("screenshot") && names.contains("capture"))
        #expect(Pipeline.v1.revisions.steps.map(\.name) == ["combiner", "frame-seam", "preview-tail"])
    }
}
