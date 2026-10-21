//
//  StableSplit.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Deterministic, auditable splits: a key (an image stem, a source, a row id) maps to a
//        number in [0, 1) by its SHA-256, and fractions of that line make train, val and test.
//  PIN:  The number is the first eight bytes of SHA-256("<salt>:<key>"), big-endian, over 2^64.
//        A salt names the split ("fusion-eval:v1" for the fusion head's evaluation twin,
//        "combiner:v1" for the combiner's test rows), so two splits of one corpus never
//        correlate. The Python splits were seeded shuffles that Swift cannot replay; these are written
//        into every manifest instead, so anyone can audit which row went where.
//

import Foundation

public enum Partition: String, Codable, Sendable, CaseIterable {
    case train, val, test
}

public enum StableSplit {
    /// SHA-256("<salt>:<key>") as a number in [0, 1).
    public static func unit(_ key: String, salt: String) -> Double {
        let bytes = ContentHash.sha256Bytes(Data("\(salt):\(key)".utf8))
        var value: UInt64 = 0
        for byte in bytes.prefix(8) { value = (value << 8) | UInt64(byte) }
        return Double(value >> 11) * 0x1.0p-53
    }

    /// Train below `train`, val below `train + val`, test above.
    public static func partition(_ key: String, salt: String, train: Double, val: Double) -> Partition {
        let u = unit(key, salt: salt)
        if u < train { return .train }
        return u < train + val ? .val : .test
    }

    /// True for the `fraction` of keys that land in the holdout.
    public static func isHoldout(_ key: String, salt: String, fraction: Double) -> Bool {
        unit(key, salt: salt) < fraction
    }
}
