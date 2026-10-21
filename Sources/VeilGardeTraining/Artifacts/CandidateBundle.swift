//
//  CandidateBundle.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Where a training run puts what it made: <work area>/candidates/<recipe id>/, a complete
//        detector bundle (the parent's artifacts, copied, with the trained ones in their place)
//        that `veilgarde route --bundle` runs and the flywheel's battery and promote read as is.
//  PIN:  Every write goes through `put`, which writes the file, hashes it, replaces that slot's
//        entry in manifest.json (recording where it came from and, for a warm start, its
//        parent's hash) and drops an inherited file nothing references any more. Weights stay
//        outside the bundle and keep the parent's expected hashes, except one the candidate
//        retrained (the noiseprint): `putWeight` writes it inside and re-pins that weight entry,
//        and the detector reads it with --weights-dir <candidate>/noiseprint. A candidate is
//        created once; a second run under the same id is refused unless asked to replace it.
//
//            candidates/<id>/
//              manifest.json  recipe.json  runs.jsonl  *.json (inherited)
//              warp/ calibration/ fusion/ combiner/        the model and its metrics.json
//              heads/<kind>/{head.json, recipe.json, metrics.json}
//              noiseprint/{noiseprint_v1.safetensors, recipe.json, metrics.json}
//

import Foundation
import VeilGardeCore

public struct CandidateBundle: Sendable {
    public let root: URL
    public let id: String
    public private(set) var manifest: BundleManifest

    public var source: String { "candidates/\(id)" }

    /// A new candidate under `area`/candidates/`id`, seeded with `parent`'s artifacts.
    public static func create(id: String, in area: WorkArea, from parent: ModelBundle, replacing: Bool = false) throws -> CandidateBundle {
        let root = area.root.appendingPathComponent("candidates/\(id)", isDirectory: true)
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path) {
            guard replacing else {
                throw VeilGardeFailure.exists("the candidate \(id) already exists at \(root.path)", hint: "choose another --id, or pass --replace")
            }
            try manager.removeItem(at: root)
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        for artifact in parent.manifest.artifacts {
            let from = parent.root.appendingPathComponent(artifact.file), to = root.appendingPathComponent(artifact.file)
            try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: to.path) { try manager.copyItem(at: from, to: to) }
        }
        let candidate = CandidateBundle(root: root, id: id, manifest: BundleManifest(artifacts: parent.manifest.artifacts, weights: parent.manifest.weights))
        try candidate.save()
        return candidate
    }

    public static func open(_ root: URL) throws -> CandidateBundle {
        let bundle = try ModelBundle.load(root)
        return CandidateBundle(root: root, id: root.lastPathComponent, manifest: bundle.manifest)
    }

    public var bundle: ModelBundle { ModelBundle(root: root, manifest: manifest) }

    public func url(_ role: ArtifactRole, head: HeadKind? = nil) -> URL? {
        manifest.artifact(role, head: head).map { root.appendingPathComponent($0.file) }
    }

    /// Writes `data` as `file` and makes it the bundle's artifact for (`role`, `head`).
    @discardableResult
    public mutating func put(_ data: Data, as file: String, role: ArtifactRole, head: HeadKind? = nil, parent: String? = nil) throws -> Artifact {
        let url = root.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let artifact = Artifact(role: role, head: head, file: file, sha256: ContentHash.sha256Hex(data), bytes: data.count, source: source, parent: parent)
        let previous = manifest.artifacts.first { $0.role == role && $0.head == head }
        manifest.artifacts.removeAll { $0.role == role && $0.head == head }
        manifest.artifacts.append(artifact)
        manifest.artifacts.sort { ($0.slot, $0.file) < ($1.slot, $1.file) }
        if let previous, previous.file != file, !manifest.artifacts.contains(where: { $0.file == previous.file }) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(previous.file))
        }
        try save()
        return artifact
    }

    /// Writes a weight the candidate retrained as `file` and makes it the expected weight for `role`.
    @discardableResult
    public mutating func putWeight(_ data: Data, as file: String, role: ArtifactRole) throws -> Artifact {
        let url = root.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let previous = manifest.weights.first { $0.role == role }
        let weight = Artifact(role: role, file: file, sha256: ContentHash.sha256Hex(data), bytes: data.count, source: source, parent: previous?.sha256)
        manifest.weights.removeAll { $0.role == role }
        manifest.weights.append(weight)
        manifest.weights.sort { ($0.slot, $0.file) < ($1.slot, $1.file) }
        try save()
        return weight
    }

    /// Writes an edited copy of an inherited artifact, a measurement variant: `put`, then the
    /// artifact's source and its parent's hash, and the history events that say what was done.
    @discardableResult
    public mutating func derive(_ data: Data, as file: String, role: ArtifactRole, head: HeadKind? = nil, source: String, parentSHA256: String?,
                                events: [BundleEvent]) throws -> Artifact {
        var artifact = try put(data, as: file, role: role, head: head, parent: parentSHA256)
        if let i = manifest.artifacts.firstIndex(where: { $0.role == role && $0.head == head }) {
            manifest.artifacts[i].source = source
            artifact = manifest.artifacts[i]
        }
        manifest.history += events
        try save()
        return artifact
    }

    /// Removes an artifact (and its file, when nothing else names it); the caller saves.
    public mutating func dropArtifact(_ artifact: Artifact) {
        manifest.artifacts.removeAll { $0.role == artifact.role && $0.head == artifact.head }
        if !manifest.artifacts.contains(where: { $0.file == artifact.file }) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(artifact.file))
        }
    }

    /// A side file (a recipe, a metrics report), pretty and sorted.
    public func write<T: Encodable>(_ value: T, as file: String) throws {
        try JSONCoding.write(value, to: root.appendingPathComponent(file))
    }

    public func save() throws {
        try JSONCoding.write(manifest, to: root.appendingPathComponent(BundleManifest.fileName))
    }

    /// Re-hashes every artifact, as a detector or the battery would on load.
    public func verify() throws { try ModelBundle.load(root).verify() }
}
