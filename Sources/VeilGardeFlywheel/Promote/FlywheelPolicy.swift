//
//  FlywheelPolicy.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What the flywheel may move, how, and what must hold first. The warp tile model and its
//        sensor copy, the fusion reference, noiseprint and the backbones are frozen: no automated
//        path ever writes them. The fusion head (the base) moves only by a warm start of the live
//        head; a calibration only when bound to the live sensor model; an atlas head only when it
//        leaves calm real photos alone.
//  PIN:  The flywheel's laws, from the promote scripts and the baseline audit: promote is the
//        sole deploy writer; the base gates on the battery's HARD groups, everything else on the
//        full battery (heads reach every arbiter); the admission pre-gate is block@0.8 ≤ 10% on
//        golden real anchors whose path does not contain "bsky", for art, blur, human and cgi.
//

import Foundation
import VeilGardeCore

public enum FlywheelSlot: Equatable, Hashable, Sendable, CustomStringConvertible {
    case base
    case combiner
    case calibration
    case head(HeadKind)

    public init(parsing name: String) throws {
        switch name {
        case "base", "fusion", "fusion-head": self = .base
        case "combiner": self = .combiner
        case "calibration", "sensor-calibration": self = .calibration
        case "pair": self = .head(.artPair)
        default:
            guard let kind = HeadKind(rawValue: name) else {
                let frozen = ["warp-tile", "warp-majority-sensor", "fusion-reference", "noiseprint", "dinov2-small", "clip-vision"]
                if frozen.contains(name) { throw VeilGardeFailure.usage("\(name) is frozen: the flywheel never promotes it") }
                throw VeilGardeFailure.usage("no promotable slot \(name); slots are base, combiner, calibration and the heads \(HeadKind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            self = .head(kind)
        }
    }

    public var role: ArtifactRole {
        switch self {
        case .base: return .fusionHead
        case .combiner: return .combiner
        case .calibration: return .sensorCalibration
        case .head: return .head
        }
    }

    public var head: HeadKind? { if case .head(let k) = self { return k } else { return nil } }

    public var description: String {
        switch self {
        case .base: return "base"
        case .combiner: return "combiner"
        case .calibration: return "calibration"
        case .head(let k): return k.rawValue
        }
    }
}

public enum FlywheelPolicy {
    public static let admissionHeads: Set<HeadKind> = [.art, .blur, .human, .cgi]
    public static let admissionCeiling = 0.10
    public static let admissionThreshold: Float = 0.8

    /// The roles no automated path writes.
    public static let frozen: [ArtifactRole] = ArtifactRole.allCases.filter(\.isFrozen)

    /// The battery a promote of `slot` must pass.
    public static func gate(for slot: FlywheelSlot) -> BatterySpec.Gate { slot == .base ? .promote : .full }

    public struct Admission: Codable, Sendable, Equatable {
        public var anchors: Int
        public var block: Double
        public var admitted: Bool
    }

    /// The heads' pre-gate: the head's block@0.8 on golden real anchors (bsky excluded).
    public static func admission(_ head: LinearHead, store: FeatureStore) throws -> Admission {
        let rows = try store.select(columns: [.dinoNorm]) { $0.golden && $0.label == 0 && !$0.path.contains("bsky") }
        var anchors = 0, blocked = 0
        for i in 0..<rows.count {
            let e = Array(rows.vector(.dinoNorm, row: i))
            guard e.first?.isFinite == true else { continue }
            anchors += 1
            if head.pAI(e) > admissionThreshold { blocked += 1 }
        }
        guard anchors > 0 else { throw VeilGardeFailure.data("no golden real anchors with dino_norm in the store: the admission gate cannot run") }
        let block = Double(blocked) / Double(anchors)
        return Admission(anchors: anchors, block: block, admitted: block <= admissionCeiling)
    }
}
