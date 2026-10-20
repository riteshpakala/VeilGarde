//
//  ModelBundle.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A directory of artifacts bound by its manifest: the shipped bundle inside the Inference
//        module, the flywheel's live bundle in the work area, a staged candidate. Loading re-hashes
//        every file the manifest names and refuses any mismatch.
//  PIN:  A bundle is exactly the bytes its manifest names; a file it does not name is ignored, and
//        a named file whose hash moved is an error, never a warning.
//

import Foundation

public struct ModelBundle: Sendable {
    public let root: URL
    public let manifest: BundleManifest

    public init(root: URL, manifest: BundleManifest) {
        self.root = root
        self.manifest = manifest
    }

    public static func load(_ root: URL, verify: Bool = true) throws -> ModelBundle {
        let manifestURL = root.appendingPathComponent(BundleManifest.fileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw VeilGardeFailure.missing("no \(BundleManifest.fileName) in \(root.path)")
        }
        let manifest: BundleManifest
        do { manifest = try JSONCoding.read(BundleManifest.self, from: manifestURL) } catch {
            throw VeilGardeFailure.data("\(manifestURL.path) is not a bundle manifest: \(error)")
        }
        guard manifest.format == BundleManifest.currentFormat else {
            throw VeilGardeFailure.data("\(manifestURL.path) is format \(manifest.format), not \(BundleManifest.currentFormat)")
        }
        let bundle = ModelBundle(root: root, manifest: manifest)
        if verify { try bundle.verify() }
        return bundle
    }

    /// Re-hashes every artifact; throws on the first missing file or moved hash.
    public func verify() throws {
        for artifact in manifest.artifacts {
            let url = root.appendingPathComponent(artifact.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VeilGardeFailure.missing("the bundle at \(root.path) names \(artifact.file), which is not there")
            }
            let actual = try ArtifactHashCache.shared.sha256(url)
            guard actual == artifact.sha256 else {
                throw VeilGardeFailure.data("\(artifact.file) hashes \(actual.prefix(12)), the manifest says \(artifact.sha256.prefix(12))",
                                            hint: "a bundle file changed outside promote; restore it or re-pin the manifest")
            }
        }
    }

    public func url(_ role: ArtifactRole, head: HeadKind? = nil) -> URL? {
        manifest.artifact(role, head: head).map { root.appendingPathComponent($0.file) }
    }

    public func sha256(_ role: ArtifactRole, head: HeadKind? = nil) -> String? {
        manifest.artifact(role, head: head)?.sha256
    }

    /// An artifact record for a file under `root`, hashed now.
    public static func record(_ role: ArtifactRole, head: HeadKind? = nil, file: String, in root: URL, source: String? = nil, parent: String? = nil) throws -> Artifact {
        let url = root.appendingPathComponent(file)
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return Artifact(role: role, head: head, file: file, sha256: try ContentHash.sha256Hex(fileAt: url), bytes: bytes, source: source, parent: parent)
    }
}

/// File hashes are provenance, not best-effort diagnostics. Cached by path and modification time,
/// so a 5 MB model is not re-read every inference and a replaced file is re-hashed.
public final class ArtifactHashCache: @unchecked Sendable {
    public static let shared = ArtifactHashCache()
    private let lock = NSLock()
    private var values: [String: (stamp: Date?, size: Int, sha: String)] = [:]

    public func sha256(_ url: URL) throws -> String {
        let key = url.standardizedFileURL.path
        let attributes = try FileManager.default.attributesOfItem(atPath: key)
        let stamp = attributes[.modificationDate] as? Date
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        lock.lock()
        if let cached = values[key], cached.stamp == stamp, cached.size == size { lock.unlock(); return cached.sha }
        lock.unlock()
        let value = try ContentHash.sha256Hex(fileAt: url)
        lock.lock()
        values[key] = (stamp, size, value)
        lock.unlock()
        return value
    }
}
