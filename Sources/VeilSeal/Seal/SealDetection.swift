//
//  SealDetection.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What detection says about a found picture: the verdict, the seal it matched and how strongly
//        (shared anchors, retraced hops, how much of the original it holds, the transform), the id an
//        interlace carried, and what a graphic needs to draw it (the shared anchors, the retraced paths
//        and the matched portion's outline, in the found picture's pixels).
//  PIN:  sealed — a stored seal is found (inliers ≥ I* and retraced hops ≥ H*), and any interlace read
//        agrees or names no stored seal; interlaceOnly — an interlace names a stored seal that is not
//        found but has partial evidence (≥ I*/2 inliers: a heavy edit); contentMismatch — an interlace
//        names a stored seal and the picture shows none of it (a copied mark); unknownSeal — an
//        interlace names a seal the store does not hold; none — nothing found.
//

import Foundation

public enum SealVerdict: String, Codable, Sendable, CaseIterable {
    case sealed, interlaceOnly, contentMismatch, unknownSeal, none

    public var words: String {
        switch self {
        case .sealed: return "sealed"
        case .interlaceOnly: return "interlace only"
        case .contentMismatch: return "content mismatch"
        case .unknownSeal: return "unknown seal"
        case .none: return "no seal"
        }
    }
}

public struct SealPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// One seal path as it reads in the found picture: its anchors' partners (nil where none) and which hops retraced.
public struct SealTrail: Codable, Sendable, Equatable {
    public var points: [SealPoint?]
    public var retraced: [Bool?]
}

/// How one stored seal reads in a found picture.
public struct SealMatch: Codable, Sendable, Equatable {
    public var id: SealID
    public var label: String?
    public var createdAt: Date
    /// Pairs whose patterns agreed, and how many of them agree on one transform.
    public var candidates: Int
    public var inliers: Int
    public var retraced: Int
    public var possible: Int
    /// The share of the original's area the found picture holds, 0–1.
    public var coverage: Double
    /// Of an 8×8 grid over the original, the cells that hold a shared anchor: how far the agreement spreads.
    public var cells: Int
    /// Shared anchors over the seal's anchors the transform puts inside the found picture at a scale it can see, 0–1.
    public var agreement: Double
    /// Found pixels per original pixel, at the original's centre.
    public var scale: Double
    public var projective: Bool
    /// The share of residual bits that agree between partners, when both were read.
    public var residualAgreement: Double?
    public var transform: SealTransform
    public var found: Bool
    /// The shared anchors in the found picture.
    public var anchors: [SealPoint]
    public var trails: [SealTrail]
    /// The original's corners in the found picture.
    public var portion: [SealPoint]
}

public struct SealDetection: Codable, Sendable, Equatable {
    public var verdict: SealVerdict
    public var match: SealMatch?
    /// The id an interlace carried, when one was read.
    public var interlaced: SealID?
    public var width: Int
    public var height: Int
    public var anchors: Int
    public var seals: Int
    public var keyFingerprint: String
    public var seconds: Double
    public var summary: String
}
