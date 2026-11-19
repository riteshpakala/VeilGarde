//
//  SealKeying.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Everything a seal draws from its key: which points a pattern compares, which residual cells
//        it orders, which bits a path's pointer reads. Without the key the comparisons are unknown, so
//        a seal cannot be read, forged or steered by someone holding only the picture.
//  PIN:  Veil8's key stream, keyed by the seal key's 32 bytes, labelled "burgundy/1/<what>". A draw
//        below n takes nextUInt64() % n. Changing a label or the draw order re-keys every seal: the
//        pinned pair digests in SealAnchorTests catch it.
//

import Foundation
import Veil8
import VeilKey

extension SealKey {
    /// The key stream for one use of the key.
    func stream(_ label: String) -> Veil8Key.KeyStream {
        // A SealKey is always 32 bytes, which is exactly what Veil8Key takes.
        Veil8Key(bytes: bytes)!.stream("burgundy/1/" + label)
    }
}

extension Veil8Key.KeyStream {
    mutating func below(_ n: Int) -> Int { Int(nextUInt64() % UInt64(n)) }
}

extension SealKey {
    /// The key kept at `url`, made the first time (VeilKey's file: 64 hex digits and a newline, mode 0600, never
    /// overwritten), so an app keeps one key for every seal it makes.
    public static func loadOrCreate(at url: URL) throws -> SealKey {
        _ = try VeilKey.loadOrCreate(at: url)
        return try SealKey(contentsOf: url)
    }
}
