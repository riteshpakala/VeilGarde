//
//  SealID.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What a pixel mark carries and what keys it: a 64-bit id, written as 16 lowercase hex digits,
//        and the 32-byte key whose derived streams lay the payload over the tiles. The default key is
//        public (SHA-256 of a fixed phrase), so anyone holding VeilGarde reads a default mark; a record
//        keeps only a key's fingerprint, never the key.
//  PIN:  Every keyed stream is seeded from SHA-256(key ‖ "vgm1/" ‖ label); the fingerprint is the first
//        8 bytes of SHA-256("vgm1/fingerprint" ‖ key). Changing a label, the phrase or the seeding
//        re-lays every mark ever made: PayloadLayoutTests pins the default layout's digest.
//

import Foundation
import VeilGardeCore

/// The 64 bits a mark carries: who or what an image was recorded as, looked up in a signature store.
public struct SealID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var value: UInt64

    public init(_ value: UInt64) { self.value = value }

    /// 16 hex digits, either case.
    public init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 16, let value = UInt64(trimmed, radix: 16) else { return nil }
        self.value = value
    }

    /// A fresh id from the system's generator.
    public static func random() -> SealID {
        var rng = SystemRandomNumberGenerator()
        return SealID(rng.next())
    }

    public var hex: String { String(format: "%016llx", value) }
    /// The first four hex digits and an ellipsis: how a caption names it.
    public var short: String { String(hex.prefix(4)) + "…" }
    public var description: String { hex }

    /// The id's 64 bits, most significant first.
    public var bits: [UInt8] { (0..<64).map { UInt8((value >> UInt64(63 - $0)) & 1) } }
    /// Big-endian bytes.
    public var bytes: [UInt8] { (0..<8).map { UInt8((value >> UInt64(56 - 8 * $0)) & 0xFF) } }

    public static func < (a: SealID, b: SealID) -> Bool { a.value < b.value }
}

extension SealID: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = SealID(hex: text) else { throw VeilGardeFailure.data("a watermark id is 16 hex digits, not \(text)") }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}

/// The 32 bytes that lay a mark's payload over the tiles: where the pilots sit, their levels, the
/// interleaver and the whitening. A mark made with one key does not decode under another (the CRC
/// binds the key's fingerprint too).
public struct SealKey: Hashable, Sendable {
    public static let byteCount = 32
    /// The phrase the public default key is the SHA-256 of.
    public static let defaultPhrase = "VeilGarde vgm1 public mark key"
    public static let `default` = SealKey(phrase: defaultPhrase)

    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else { throw VeilGardeFailure.data("a watermark key is \(Self.byteCount) bytes, not \(bytes.count)") }
        self.bytes = bytes
    }

    /// The SHA-256 of a phrase as a key.
    public init(phrase: String) { bytes = ContentHash.sha256Bytes(Data(phrase.utf8)) }

    /// A key file: 32 raw bytes, or 64 hex digits (whitespace ignored).
    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        if data.count == Self.byteCount {
            try self.init(bytes: [UInt8](data))
            return
        }
        let text = String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }
        guard text.count == 2 * Self.byteCount else { throw VeilGardeFailure.data("\(url.lastPathComponent) holds neither 32 bytes nor 64 hex digits") }
        var out: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { throw VeilGardeFailure.data("\(url.lastPathComponent) is not hex") }
            out.append(byte)
            index = next
        }
        try self.init(bytes: out)
    }

    /// Eight bytes that name the key without revealing it: what a record and the CRC carry.
    public var fingerprintBytes: [UInt8] { Array(ContentHash.sha256Bytes(Data("vgm1/fingerprint".utf8) + Data(bytes)).prefix(8)) }
    public var fingerprint: String { fingerprintBytes.map { String(format: "%02x", $0) }.joined() }
    public var isDefault: Bool { self == .default }

    /// A generator for one use of the key, seeded from SHA-256(key ‖ "vgm1/" ‖ label).
    func generator(_ label: String) -> SplitMix64 {
        let digest = ContentHash.sha256Bytes(Data(bytes) + Data("vgm1/\(label)".utf8))
        let seed = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return SplitMix64(seed: seed)
    }
}
