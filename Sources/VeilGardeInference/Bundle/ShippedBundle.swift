//
//  ShippedBundle.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The detector bundle this package ships: the artifacts it was verified with, bound by
//        manifest.json. Everything that reads a shipped artifact asks here, by role.
//  PIN:  The only file that writes `Bundle.module` (PackageLayeringTests). The bundle is verified
//        once per process the first time it is used: every artifact re-hashed against the
//        manifest, a mismatch refused. Its resource folder is registered with the WeightLocator,
//        after the work area's weights/, for weights copied into the Inference resources.
//

import Foundation

public enum ShippedBundle {
    /// The folder holding manifest.json and the artifacts.
    public static let directory: URL = {
        let module = Bundle.module
        for candidate in [module.resourceURL, module.bundleURL].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: candidate.appendingPathComponent(BundleManifest.fileName).path) {
            return candidate
        }
        if let manifest = module.url(forResource: "manifest", withExtension: "json") { return manifest.deletingLastPathComponent() }
        fatalError("VeilGardeInference's resource bundle has no manifest.json; rebuild the package")
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var verifiedBundle: ModelBundle?
    nonisolated(unsafe) private static var registered = false

    /// The manifest as shipped (not re-hashed).
    public static let manifest: BundleManifest = {
        do { return try JSONCoding.read(BundleManifest.self, from: directory.appendingPathComponent(BundleManifest.fileName)) } catch {
            fatalError("the shipped manifest.json does not decode: \(error)")
        }
    }()

    /// The shipped bundle, every artifact re-hashed once per process.
    public static func verified() throws -> ModelBundle {
        lock.lock()
        defer { lock.unlock() }
        if let verifiedBundle { return verifiedBundle }
        let bundle = try ModelBundle.load(directory)
        verifiedBundle = bundle
        return bundle
    }

    /// The shipped artifact for a role; every role the detector reads is in the manifest.
    public static func url(_ role: ArtifactRole, head: HeadKind? = nil) -> URL {
        guard let artifact = manifest.artifact(role, head: head) else {
            fatalError("the shipped bundle has no \(head.map { "head:\($0.rawValue)" } ?? role.rawValue)")
        }
        return directory.appendingPathComponent(artifact.file)
    }

    /// Registers the weight folders: the work area's weights/ (when there is a work area), then
    /// this bundle's resources. Idempotent.
    public static func registerWeightFolders(workArea: WorkArea? = WorkArea.resolve()) {
        lock.lock()
        defer { lock.unlock() }
        guard !registered else { return }
        registered = true
        if let workArea { WeightLocator.shared.register(workArea.weights) }
        WeightLocator.shared.register(directory)
    }
}
