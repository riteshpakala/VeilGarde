//
//  BundleTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The shipped bundle is exactly the bytes its manifest names (the camera head and the
//        combiner trained here on 2026-10-21, six heads); a moved file is refused; the frozen roles
//        are the weights, which the flywheel may never promote over.
//

import Foundation
import Testing
@testable import VeilGardeCore

@Suite("Bundle manifest")
struct BundleTests {
    @Test("the shipped bundle's manifest verifies every artifact")
    func shippedBundleVerifies() throws {
        let bundle = try ModelBundle.load(Fixture.resources)
        #expect(bundle.manifest.artifacts.count == 8)
        #expect(bundle.manifest.weights.count == 3)
        #expect(bundle.sha256(.camera) == "b142e661c609070a7838fb015ae47a8b9ccce2ab1d539c3dac29afadc48b8f9e")
        #expect(bundle.manifest.artifact(.camera)?.file == "camera.xgb.json" && bundle.manifest.artifact(.combiner)?.file == "stack_combiner.json")
        #expect(bundle.sha256(.combiner) == ContentHash.sha256Hex(try Data(contentsOf: Fixture.resource("stack_combiner.json"))))
        #expect(bundle.manifest.artifact(.camera)?.parent == nil, "a scratch fit continues no parent")
        for head in HeadKind.allCases { #expect(bundle.url(.head, head: head) != nil, "no \(head.rawValue) head") }
        #expect(bundle.manifest.history.map(\.kind) == [.seed] && bundle.manifest.history.first?.slot == "bundle", "v1 starts its history fresh")
    }

    @Test("a file that moved under its manifest is refused")
    func tamperRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vg-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("a.json"))
        let manifest = BundleManifest(artifacts: [try ModelBundle.record(.combiner, file: "a.json", in: dir)])
        try JSONCoding.write(manifest, to: dir.appendingPathComponent(BundleManifest.fileName))
        _ = try ModelBundle.load(dir)
        try Data("{ }".utf8).write(to: dir.appendingPathComponent("a.json"))
        #expect(throws: VeilGardeFailure.self) { try ModelBundle.load(dir) }
    }

    @Test("frozen roles are the weights")
    func frozenRoles() {
        let frozen = Set(ArtifactRole.allCases.filter(\.isFrozen))
        #expect(frozen == [.dinov2Small, .dinov2XSmall, .dinov2XXSmall, .clipVision])
        #expect(!ArtifactRole.camera.isFrozen && !ArtifactRole.head.isFrozen && !ArtifactRole.combiner.isFrozen)
    }
}
