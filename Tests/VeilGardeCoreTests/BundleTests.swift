//
//  BundleTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The shipped bundle is exactly the bytes its manifest names; a moved file is refused; the
//        frozen roles are the ones the flywheel may never promote over.
//

import Foundation
import Testing
@testable import VeilGardeCore

@Suite("Bundle manifest")
struct BundleTests {
    @Test("the shipped bundle's manifest verifies every artifact")
    func shippedBundleVerifies() throws {
        let bundle = try ModelBundle.load(Fixture.resources)
        #expect(bundle.manifest.artifacts.count == 14)
        #expect(bundle.manifest.weights.count == 4)
        #expect(bundle.sha256(.warpTile) == "516119c92d364dda3dba41dcfc42e06edf0f42e45efd3b54c44ab620f7eefe3d")
        #expect(bundle.sha256(.warpTile) == bundle.sha256(.warpMajoritySensor))
        #expect(bundle.manifest.artifact(.fusionHead)?.parent == bundle.sha256(.fusionReference))
        for head in HeadKind.allCases where head != .artPair { #expect(bundle.url(.head, head: head) != nil, "no \(head.rawValue) head") }
        #expect(bundle.url(.head, head: .artPair) == nil, "the art-pair head left the bundle with its adjudicator")
        #expect(bundle.manifest.history.map(\.slot).suffix(2) == ["calibration", "combiner"], "the two cuts and the combiner without the art-pair, recorded")
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

    @Test("frozen roles are the warp models, the fusion reference, noiseprint and the backbones")
    func frozenRoles() {
        let frozen = Set(ArtifactRole.allCases.filter(\.isFrozen))
        #expect(frozen == [.warpTile, .warpMajoritySensor, .fusionReference, .noiseprint, .dinov2Small, .dinov2XSmall, .dinov2XXSmall, .clipVision])
        #expect(!ArtifactRole.fusionHead.isFrozen && !ArtifactRole.head.isFrozen && !ArtifactRole.combiner.isFrozen)
    }
}
