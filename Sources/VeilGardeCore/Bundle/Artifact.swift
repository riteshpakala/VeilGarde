//
//  Artifact.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: One file a detector bundle holds, named by its role (the warp tile model, the sensor
//        calibration, the fusion head, a specialist head, …) and bound by its SHA-256, size,
//        provenance and, for a warm-started model, its parent's hash.
//  PIN:  `frozen` marks what the flywheel may never move: the warp tile model and its sensor
//        copy, the fusion reference, noiseprint and the backbones (Flywheel/Promote's policy reads
//        it). A file's name is free; what binds it is its hash: the result JSON reports the warp
//        models' hashes and the calibration is bound to the sensor model's bytes.
//

public enum ArtifactRole: String, Codable, Sendable, CaseIterable {
    case warpTile = "warp-tile"
    case warpMajoritySensor = "warp-majority-sensor"
    case sensorCalibration = "sensor-calibration"
    case fusionHead = "fusion-head"
    case fusionReference = "fusion-reference"
    case combiner
    case xDomainCentroids = "xdomain-centroids"
    case head
    case dinov2Small = "dinov2-small"
    case dinov2XSmall = "dinov2-xsmall"
    case dinov2XXSmall = "dinov2-xxsmall"
    case noiseprint
    case clipVision = "clip-vision"

    /// Roles the flywheel may never promote over.
    public var isFrozen: Bool {
        switch self {
        case .warpTile, .warpMajoritySensor, .fusionReference, .noiseprint, .dinov2Small, .dinov2XSmall, .dinov2XXSmall, .clipVision: return true
        case .sensorCalibration, .fusionHead, .combiner, .xDomainCentroids, .head: return false
        }
    }

    /// Weights live outside the bundle (gitignored, resolved by the Lens's WeightLocator).
    public var isWeights: Bool {
        switch self {
        case .dinov2Small, .dinov2XSmall, .dinov2XXSmall, .noiseprint, .clipVision: return true
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
    /// Where the bytes came from: "garde@dbc6277", "candidates/<recipe>", "garde WeightOverride".
    public var source: String?
    /// The hash of the artifact this one continues (a warm-started fusion head's parent).
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
