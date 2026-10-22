//
//  Artifact.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: One file a detector bundle holds, named by its role (the camera head, the combiner, a
//        linear head, a weight) and bound by its SHA-256, size, provenance and, for a warm-started
//        model, its parent's hash.
//  PIN:  `frozen` marks what the flywheel may never move: the weights, the embeddings every model
//        was trained on (Flywheel/Promote's policy reads it). A file's name is free; what binds it
//        is its hash.
//

public enum ArtifactRole: String, Codable, Sendable, CaseIterable {
    case camera
    case combiner
    case head
    case dinov2Small = "dinov2-small"
    case dinov2XSmall = "dinov2-xsmall"
    case dinov2XXSmall = "dinov2-xxsmall"
    case clipVision = "clip-vision"

    /// Roles the flywheel may never promote over: the weights.
    public var isFrozen: Bool {
        switch self {
        case .dinov2Small, .dinov2XSmall, .dinov2XXSmall, .clipVision: return true
        case .camera, .combiner, .head: return false
        }
    }

    /// Weights live outside the bundle (gitignored, resolved by the Lens's WeightLocator).
    public var isWeights: Bool {
        switch self {
        case .dinov2Small, .dinov2XSmall, .dinov2XXSmall, .clipVision: return true
        default: return false
        }
    }
}

public struct Artifact: Codable, Sendable, Equatable {
    public var role: ArtifactRole
    public var head: HeadKind?
    public var file: String
    public var sha256: String
    public var bytes: Int
    /// Where the bytes came from: "candidates/<recipe>", an import, the research's heads.
    public var source: String?
    /// The hash of the artifact this one continues (a warm-started camera head's parent).
    public var parent: String?

    public init(role: ArtifactRole, head: HeadKind? = nil, file: String, sha256: String, bytes: Int, source: String? = nil, parent: String? = nil) {
        self.role = role
        self.head = head
        self.file = file
        self.sha256 = sha256
        self.bytes = bytes
        self.source = source
        self.parent = parent
    }

    public var frozen: Bool { role.isFrozen }

    /// "role" or "head:<kind>", the name promote and the CLI use.
    public var slot: String { head.map { "head:\($0.rawValue)" } ?? role.rawValue }
}
