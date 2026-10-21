//
//  DetectorBundle.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The set of artifacts one detection reads: the shipped bundle by default, or another
//        hash-bound bundle directory (the flywheel's live bundle, a staged candidate) so the
//        battery can judge exactly what promote would deploy.
//  PIN:  A loaded bundle is verified (every artifact re-hashed against its manifest); the shipped
//        one is verified once per process by ShippedBundle. Artifacts are resolved by role, never
//        by file name, so a promoted head under a new name is found.
//

import Foundation

public struct DetectorBundle: Sendable, Equatable {
    public let directory: URL
    public let manifest: BundleManifest

    public init(directory: URL, manifest: BundleManifest) {
        self.directory = directory
        self.manifest = manifest
    }

    /// The bundle the package ships.
    public static var shipped: DetectorBundle { DetectorBundle(directory: ShippedBundle.directory, manifest: ShippedBundle.manifest) }

    /// A bundle directory, every artifact verified.
    public static func load(_ directory: URL) throws -> DetectorBundle {
        let bundle = try ModelBundle.load(directory)
        return DetectorBundle(directory: bundle.root, manifest: bundle.manifest)
    }

    public func url(_ role: ArtifactRole, head: HeadKind? = nil) -> URL? {
        manifest.artifact(role, head: head).map { directory.appendingPathComponent($0.file) }
    }

    public var isShipped: Bool { directory.standardizedFileURL == ShippedBundle.directory.standardizedFileURL }

    /// The hashes a result reports: the fusion head's, the combiner's and the manifest's.
    public var hashes: BundleHashes {
        let manifestSHA = (try? JSONCoding.prettyEncoder().encode(manifest)).map { ContentHash.sha256Hex($0) } ?? ""
        return BundleHashes(fusionHeadSHA256: manifest.artifact(.fusionHead)?.sha256, combinerSHA256: manifest.artifact(.combiner)?.sha256,
                            manifestSHA256: manifestSHA)
    }

    /// What a report names to say which models it measured: the bundle's directory, the fusion
    /// head's and the combiner's hashes, and the manifest's hash.
    public var provenance: [String: String] {
        let h = hashes
        var out = ["bundle": directory.path, "manifest_sha256": h.manifestSHA256]
        if let f = h.fusionHeadSHA256 { out["fusion_head_sha256"] = f }
        if let c = h.combinerSHA256 { out["combiner_sha256"] = c }
        return out
    }
}
