//
//  ShippedBundleTests.swift
//  VeilGardeInferenceTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The shipped bundle verifies, holds the fusion head and the combiner trained on 2026-10-21
//        and the six heads, and the detector's defaults point into it at its one operating point.
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
        #expect(bundle.manifest.artifact(.fusionHead)?.sha256 == "b142e661c609070a7838fb015ae47a8b9ccce2ab1d539c3dac29afadc48b8f9e")
        #expect(bundle.manifest.artifact(.combiner)?.file == "stack_combiner_v3.json")
        #expect(bundle.manifest.artifact(.head, head: .artPair) == nil && bundle.manifest.artifact(.head, head: .cgi) == nil)
        let config = InferenceConfig()
        #expect(config.bundle.isShipped && config.decision == .fusion && config.dinoVariant == .small && config.semanticResponsibility == .control)
        #expect(config.bundle.url(.fusionHead)?.lastPathComponent == "fusion_head.xgb.json")
    }

    @Test("the shipped combiner loads without a noiseprint term")
    func combiner() throws {
        let c = try #require(HeadRegistry.shared.combiner(in: .shipped))
        #expect(c.wGen.count == 3 && c.pairAdjudicates == false)
    }
}
