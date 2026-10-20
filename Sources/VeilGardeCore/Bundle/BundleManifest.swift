//
//  BundleManifest.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The manifest every detector bundle carries (manifest.json): its artifacts by role, the
//        expected hashes of the weights that live outside it, and, for the flywheel's live
//        bundle, the history of every promote and rollback.
//  PIN:  One format for the shipped bundle (Sources/VeilGardeInference/Resources) and the live one
//        (<work area>/live): ModelBundle.load re-hashes every file and refuses a mismatch, so a
//        bundle is exactly the bytes its manifest names.
//

import Foundation

public struct BundleEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case seed, promote, rollback }
    public var date: Date
    public var kind: Kind
    public var slot: String
    public var fromSHA256: String?
    public var toSHA256: String?
    public var battery: String?
    public var note: String?

    public init(date: Date, kind: Kind, slot: String, fromSHA256: String? = nil, toSHA256: String? = nil, battery: String? = nil, note: String? = nil) {
        self.date = date
        self.kind = kind
        self.slot = slot
        self.fromSHA256 = fromSHA256
        self.toSHA256 = toSHA256
        self.battery = battery
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case date, kind, slot, battery, note
        case fromSHA256 = "from_sha256"
        case toSHA256 = "to_sha256"
    }
}

public struct BundleManifest: Codable, Sendable, Equatable {
    public static let currentFormat = "veilgarde-bundle-v1"
    public static let fileName = "manifest.json"

    public var format: String
    public var artifacts: [Artifact]
    /// The weights the bundle expects beside it, by hash.
    public var weights: [Artifact]
    public var history: [BundleEvent]

    public init(artifacts: [Artifact], weights: [Artifact] = [], history: [BundleEvent] = []) {
        self.format = Self.currentFormat
        self.artifacts = artifacts
        self.weights = weights
        self.history = history
    }

    public func artifact(_ role: ArtifactRole, head: HeadKind? = nil) -> Artifact? {
        artifacts.first { $0.role == role && $0.head == head }
    }

    public func artifact(slot: String) -> Artifact? { artifacts.first { $0.slot == slot } }

    public func weight(_ role: ArtifactRole) -> Artifact? { weights.first { $0.role == role } }
}
