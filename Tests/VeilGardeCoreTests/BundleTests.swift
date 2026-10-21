//
//  BundleTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The shipped bundle is exactly the bytes its manifest names (the fusion head and the combiner
//        trained here on 2026-10-21, six heads); a moved file is refused; the frozen roles are the
//        weights, which the flywheel may never promote over.
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
        #expect(bundle.sha256(.fusionHead) == "b142e661c609070a7838fb015ae47a8b9ccce2ab1d539c3dac29afadc48b8f9e")
        #expect(bundle.sha256(.combiner) == "cdd0cb2e40fe7127482a0c66c3cb26df814dee26db297985f50ea5fe93d99f52")
        #expect(bundle.manifest.artifact(.fusionHead)?.parent == nil, "a scratch fit continues no parent")
        for head in [HeadKind.screenshot, .art, .blur, .human, .semtile, .preview] { #expect(bundle.url(.head, head: head) != nil, "no \(head.rawValue) head") }
        #expect(bundle.url(.head, head: .artPair) == nil, "the art-pair head left the bundle with its adjudicator")
        #expect(bundle.url(.head, head: .cgi) == nil, "the cgi head left the bundle with the render arbiter")
        #expect(bundle.manifest.history.map(\.slot).suffix(3) == ["bundle", "base", "combiner"], "the warp's removal and the two refits, recorded")
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
        #expect(!ArtifactRole.fusionHead.isFrozen && !ArtifactRole.head.isFrozen && !ArtifactRole.combiner.isFrozen)
    }
}
