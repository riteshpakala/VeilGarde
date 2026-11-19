//
//  SealRecord.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What a store keeps for one marked image: the id its pixels carry, the label it was recorded as,
//        the key's fingerprint, the passive signature of the marked PNG as decoded, the PNG's SHA-256,
//        the settings it was marked with and how the embed went. Detection looks the id up here and
//        checks the image's content against the signature.
//  PIN:  The signature is always SealGrid.sign of the marked PNG as a reader decodes it, so it matches
//        that image at offset 0 with score 1. `cid` repeats the signature's and is checked on every
//        read: a record whose words and cid disagree is refused. The key itself is never kept.
//

import Foundation

public struct SealRecord: Codable, Sendable, Equatable {
    public static let currentFormat = "veilgarde-mark-record"
    public static let currentVersion = 1
    public static let markVersion = "vgm1"

    public var format: String
    public var version: Int
    public var mark: String
    public var id: SealID
    /// Who or what the image was recorded as, in the person's words.
    public var label: String?
    public var keyFingerprint: String
    public var signature: GridSignature
    public var cid: String
    public var pngSHA256: String
    public var width: Int
    public var height: Int
    /// The file it was made from, by name only.
    public var sourceName: String?
    public var createdAt: Date
    public var settings: MarkSettings
    public var report: EmbedReport

    public init(id: SealID, label: String?, keyFingerprint: String, signature: GridSignature, pngSHA256: String, width: Int, height: Int,
                sourceName: String?, createdAt: Date = Date(), settings: MarkSettings, report: EmbedReport) {
        format = Self.currentFormat
        version = Self.currentVersion
        mark = Self.markVersion
        self.id = id
        self.label = label
        self.keyFingerprint = keyFingerprint
        self.signature = signature
        cid = signature.cid
        self.pngSHA256 = pngSHA256
        self.width = width
        self.height = height
        self.sourceName = sourceName
        // Whole seconds: the store writes ISO 8601, so a record reads back equal.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.settings = settings
        self.report = report
    }

    /// The 96 message bits the image's pixels carry (the CRC needs only the fingerprint).
    public var messageBits: [UInt8]? {
        PayloadCode.fingerprintBytes(keyFingerprint).map { PayloadCode.message(id: id, fingerprint: $0) }
    }
}
