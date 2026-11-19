//
//  SealRecord.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Step 7, the signature: what a store keeps for one sealed picture (burgundy/1). Its anchors
//        (place, scale, orientation, pattern, warp residual), its paths, the picture's size and bytes'
//        SHA-256, the key's fingerprint (never the key), the label it was sealed as and, when a hidden
//        copy was made, how it was interlaced.
//  PIN:  cid = SHA-256 of the body (format, key fingerprint, measure, image, anchors, paths, interlace)
//        as sorted-key JSON; id = the first 16 hex digits of the cid of the picture as first sealed (an
//        interlaced seal keeps that id, and its anchors and cid are the interlaced copy's as decoded).
//        Label and date are outside the cid: sealing the same picture again names the same seal.
//

import Foundation
import VeilGardeCore

public struct SealImageFacts: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// SHA-256 of the file's bytes.
    public var sha256: String
    /// The file's name, never its folder.
    public var name: String?
}

public struct SealInterlaceFacts: Codable, Sendable, Equatable {
    /// "vgm1" until the anchor interlace passes its bars.
    public var carrier: String
    /// "signature": the seal's id.
    public var payload: String
    public var report: EmbedReport?
}

public struct SealRecord: Codable, Sendable, Equatable {
    public static let currentFormat = "burgundy/1"

    public var format: String
    public var id: SealID
    public var label: String?
    public var createdAt: Date
    public var keyFingerprint: String
    public var measure: String
    public var image: SealImageFacts
    public var anchors: [Anchor]
    public var paths: [SealPath]
    public var interlace: SealInterlaceFacts?
    public var cid: String

    struct Body: Encodable {
        var format: String
        var keyFingerprint: String
        var measure: String
        var image: SealImageFacts
        var anchors: [Anchor]
        var paths: [SealPath]
        var interlace: SealInterlaceFacts?
    }

    static let bodyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// The cid of a body.
    static func cid(keyFingerprint: String, measure: String, image: SealImageFacts, anchors: [Anchor], paths: [SealPath],
                    interlace: SealInterlaceFacts?) throws -> String {
        let body = Body(format: currentFormat, keyFingerprint: keyFingerprint, measure: measure, image: image, anchors: anchors, paths: paths,
                        interlace: interlace)
        return ContentHash.sha256Hex(try bodyEncoder.encode(body))
    }

    /// A record whose id is its own cid's prefix, or `id` when given (an interlaced copy keeps its source's).
    init(id: SealID?, label: String?, createdAt: Date = Date(), keyFingerprint: String, measure: String, image: SealImageFacts,
         anchors: [Anchor], paths: [SealPath], interlace: SealInterlaceFacts?) throws {
        format = Self.currentFormat
        cid = try Self.cid(keyFingerprint: keyFingerprint, measure: measure, image: image, anchors: anchors, paths: paths, interlace: interlace)
        self.id = id ?? SealID(hex: String(cid.prefix(16)))!
        self.label = label
        // Whole seconds: the store writes ISO 8601, so a record reads back equal.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.keyFingerprint = keyFingerprint
        self.measure = measure
        self.image = image
        self.anchors = anchors
        self.paths = paths
        self.interlace = interlace
    }

    /// Whether the cid is the body's.
    var isIntact: Bool {
        (try? Self.cid(keyFingerprint: keyFingerprint, measure: measure, image: image, anchors: anchors, paths: paths, interlace: interlace)) == cid
    }

    /// Hops over all paths.
    public var hopCount: Int { paths.reduce(0) { $0 + $1.hops.count } }

    /// The signature string: each path's patterns one after another, paths joined by " · ". `limit`
    /// characters at most (with an ellipsis), for a caption.
    public func signature(limit: Int = .max) -> String {
        let text = paths.map { path in path.anchors.map { String(anchors[$0].code.hex.prefix(4)) }.joined(separator: "→") }.joined(separator: " · ")
        return text.count > limit ? String(text.prefix(max(0, limit - 1))) + "…" : text
    }
}
