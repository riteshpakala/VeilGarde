//
//  FlywheelPolicy.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What the flywheel may move, how, and what must hold first. The backbones' weights are
//        frozen: no automated path ever writes them. The camera head moves only by a warm start of
//        the live head; the combiner only with non-negative weights over members live holds; a
//        category head only when it leaves calm real photos alone.
//  PIN:  The flywheel's laws, from the promote scripts and the baseline audit: promote is the
//        sole deploy writer; the camera head gates on the battery's HARD groups, everything else
//        on the full battery (heads reach every revision); the admission pre-gate is block@0.8 ≤
//        10% on golden real anchors whose path does not contain "bsky", for art, blur and human.
//

import Foundation
import VeilGardeCore

public enum FlywheelSlot: Equatable, Hashable, Sendable, CustomStringConvertible {
    case camera
    case combiner
    case head(HeadKind)

    public init(parsing name: String) throws {
        switch name {
        case "camera": self = .camera
        case "combiner": self = .combiner
        default:
            guard let kind = HeadKind(rawValue: name) else {
                if ArtifactRole.allCases.filter(\.isFrozen).map(\.rawValue).contains(name) {
                    throw VeilGardeFailure.usage("\(name) is frozen: the flywheel never promotes it")
                }
                throw VeilGardeFailure.usage("no promotable slot \(name); slots are camera, combiner and the heads \(HeadKind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            self = .head(kind)
        }
    }

    public var role: ArtifactRole {
        switch self {
        case .camera: return .camera
        case .combiner: return .combiner
        case .head: return .head
        }
    }

    public var head: HeadKind? { if case .head(let k) = self { return k } else { return nil } }

    public var description: String {
        switch self {
        case .camera: return "camera"
        case .combiner: return "combiner"
        case .head(let k): return k.rawValue
        }
    }
}

public enum FlywheelPolicy {
    public static let admissionHeads: Set<HeadKind> = [.art, .blur, .human]
    public static let admissionCeiling = 0.10
    public static let admissionThreshold: Float = 0.8

    /// The roles no automated path writes.
    public static let frozen: [ArtifactRole] = ArtifactRole.allCases.filter(\.isFrozen)

    /// The battery a promote of `slot` must pass.
    public static func gate(for slot: FlywheelSlot) -> BatterySpec.Gate { slot == .camera ? .promote : .full }

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
