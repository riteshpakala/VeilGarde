//
//  PayloadCode.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The mark's payload and its error-correcting code: the 64-bit id and a CRC-32C over the key's
//        fingerprint and the id (96 bits), through a terminated convolutional code of constraint 7 and
//        rate ½ (204 coded bits), decoded by a soft-decision Viterbi.
//  PIN:  CRC-32C is the reflected Castagnoli polynomial 0x82F63B78, initial and final XOR 0xFFFFFFFF
//        (check value 0xE3069283 on "123456789"). The code's generators are 171 and 133 octal over a
//        7-bit register whose bit 6 is the current input; six zero tail bits return it to state 0.
//        A soft value is positive for a 1. The CRC binds the key: a mark made under one key fails it
//        under another, so a wrong key reads as no mark, never as a wrong id.
//

import Foundation

public enum PayloadCode {
    public static let idBits = 64
    public static let crcBits = 32
    public static let messageBits = idBits + crcBits          // 96
    public static let constraint = 7
    public static let tailBits = constraint - 1               // 6
    public static let codedBits = 2 * (messageBits + tailBits) // 204

    static let generators: (UInt8, UInt8) = (0o171, 0o133)

    // MARK: CRC-32C

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0x82F6_3B78 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32c(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: Message

    /// The 96 message bits for `id` under `key`, most significant first: the id, then its CRC.
    public static func message(id: SealID, key: SealKey) -> [UInt8] { message(id: id, fingerprint: key.fingerprintBytes) }

    /// The same from the key's fingerprint alone, which is all a record keeps.
    public static func message(id: SealID, fingerprint: [UInt8]) -> [UInt8] {
        let crc = crc32c(fingerprint + id.bytes)
        return id.bits + (0..<crcBits).map { UInt8((crc >> UInt32(31 - $0)) & 1) }
    }

    /// A fingerprint's 16 hex digits as its 8 bytes.
    public static func fingerprintBytes(_ hex: String) -> [UInt8]? {
        guard hex.count == 16 else { return nil }
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// The id a decoded message carries, when its CRC holds under `key`.
    public static func id(fromMessage bits: [UInt8], key: SealKey) -> SealID? {
        guard bits.count == messageBits else { return nil }
        let value = bits.prefix(idBits).reduce(UInt64(0)) { ($0 << 1) | UInt64($1 & 1) }
        let id = SealID(value)
        return message(id: id, key: key) == bits ? id : nil
    }

    // MARK: Convolutional code

    @inline(__always) private static func parity(_ x: UInt8) -> UInt8 { UInt8(x.nonzeroBitCount & 1) }

    /// The coded bits for `bits` (tail appended): two per input bit, in order.
    public static func encode(_ bits: [UInt8]) -> [UInt8] {
        var state: UInt8 = 0
        var out: [UInt8] = []
        out.reserveCapacity(2 * (bits.count + tailBits))
        for u in bits + [UInt8](repeating: 0, count: tailBits) {
            let register = ((u & 1) << 6) | state
            out.append(parity(register & generators.0))
            out.append(parity(register & generators.1))
            state = register >> 1
        }
        return out
    }

    /// The most likely input bits for `soft` coded values (positive means 1), the tail dropped. The
    /// trellis starts and ends in state 0.
    public static func decode(_ soft: [Float]) -> [UInt8] {
        let steps = soft.count / 2
        guard steps > tailBits else { return [] }
        let states = 64
        var metric = [Float](repeating: -.infinity, count: states)
        metric[0] = 0
        var survivors = [UInt8](repeating: 0, count: steps * states)   // previous state, per step and state
        var next = [Float](repeating: -.infinity, count: states)
        // Each state's two branches' code bits, as ±1, precomputed per (state, input).
        var signs = [(Float, Float)](repeating: (0, 0), count: 2 * states)
        for s in 0..<states {
            for u in 0..<2 {
                let register = UInt8(u << 6) | UInt8(s)
                signs[2 * s + u] = (parity(register & generators.0) == 1 ? 1 : -1, parity(register & generators.1) == 1 ? 1 : -1)
            }
        }
        for t in 0..<steps {
            let y0 = soft[2 * t], y1 = soft[2 * t + 1]
            for i in 0..<states { next[i] = -.infinity }
            let lastInputs = t >= steps - tailBits ? 1 : 2   // the tail only shifts zeros in
            for s in 0..<states where metric[s] > -.infinity {
                for u in 0..<lastInputs {
                    let (a, b) = signs[2 * s + u]
                    let m = metric[s] + y0 * a + y1 * b
                    let ns = (u << 5) | (s >> 1)
                    if m > next[ns] {
                        next[ns] = m
                        survivors[t * states + ns] = UInt8(s)
                    }
                }
            }
            swap(&metric, &next)
        }
        var bits = [UInt8](repeating: 0, count: steps)
        var state = 0
        for t in stride(from: steps - 1, through: 0, by: -1) {
            bits[t] = UInt8(state >> 5)
            state = Int(survivors[t * states + state])
        }
        return Array(bits.prefix(steps - tailBits))
    }
}
