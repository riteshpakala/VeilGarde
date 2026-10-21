//
//  ContentHash.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The hashes VeilGarde's provenance rests on: an artifact's SHA-256 (what a manifest binds
//        and the result JSON's bundle block reports), a file's bytes streamed, and the SHA-1 a
//        feature-store row is named by.
//  PIN:  Every hash is lowercase hex. SHA-256 binds artifacts; SHA-1 of the image bytes is the
//        feature store's row id because the 138k-row seed store already uses it (store_ingest.py
//        `_sha1`), so a row ingested here and one ingested by the Python ingest share an id.
//

import Crypto
import Foundation

public enum ContentHash {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of the UTF-8 bytes of `text`, exactly as given (no canonicalization).
    public static func sha256Hex(_ text: String) -> String { sha256Hex(Data(text.utf8)) }

    /// SHA-256 of `parts` laid end to end, without joining them first.
    public static func sha256Hex(parts: [Data]) -> String {
        var hasher = SHA256()
        for part in parts { hasher.update(data: part) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of a file's bytes, streamed in 1 MiB chunks.
    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The 32 raw bytes of SHA-256, for seeded splits and signature ids.
    public static func sha256Bytes(_ data: Data) -> [UInt8] { Array(SHA256.hash(data: data)) }

    /// SHA-1 of the bytes: the feature store's row id.
    public static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
