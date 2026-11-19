//
//  NeighbourhoodMeasure.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What an anchor's neighbourhood is written as: 256 keyed bits from its canonical square (the
//        "pattern"), compared by Hamming distance. A measure decides which comparisons make the bits;
//        HSLPattern is the first, and the others the plan names (structure, phase, census) plug in here
//        to be measured against the same anchors.
//  PIN:  A code is four UInt64 words, written as 64 hex digits, bit n in word n / 64 at 63 − n % 64.
//        `pointerBits` are the bits a path reads to choose its next anchor: the measure's steadiest,
//        fixed per measure and key, so one flipped bit elsewhere never sends a path somewhere else.
//

import Foundation

/// 256 bits.
public struct Code256: Hashable, Sendable, Codable, CustomStringConvertible {
    public var a: UInt64
    public var b: UInt64
    public var c: UInt64
    public var d: UInt64

    public init(_ a: UInt64 = 0, _ b: UInt64 = 0, _ c: UInt64 = 0, _ d: UInt64 = 0) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
    }

    public init?(hex: String) {
        guard hex.count == 64 else { return nil }
        var words: [UInt64] = []
        var index = hex.startIndex
        for _ in 0..<4 {
            let next = hex.index(index, offsetBy: 16)
            guard let w = UInt64(hex[index..<next], radix: 16) else { return nil }
            words.append(w)
            index = next
        }
        self.init(words[0], words[1], words[2], words[3])
    }

    public var hex: String { String(format: "%016llx%016llx%016llx%016llx", a, b, c, d) }
    public var description: String { hex }

    @inline(__always) public func distance(_ o: Code256) -> Int {
        (a ^ o.a).nonzeroBitCount + (b ^ o.b).nonzeroBitCount + (c ^ o.c).nonzeroBitCount + (d ^ o.d).nonzeroBitCount
    }

    @inline(__always) public func bit(_ n: Int) -> Bool {
        let word: UInt64
        switch n >> 6 {
        case 0: word = a
        case 1: word = b
        case 2: word = c
        default: word = d
        }
        return (word >> UInt64(63 - (n & 63))) & 1 == 1
    }

    mutating func set(_ n: Int) {
        let mask = UInt64(1) << UInt64(63 - (n & 63))
        switch n >> 6 {
        case 0: a |= mask
        case 1: b |= mask
        case 2: c |= mask
        default: d |= mask
        }
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let code = Code256(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not 64 hex digits"))
        }
        self = code
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// How a canonical square becomes a code.
public protocol NeighbourhoodMeasure: Sendable {
    /// The name its key stream and its records use ("hsl").
    var name: String { get }
    /// The bits a path's pointer reads, steadiest first.
    var pointerBits: [Int] { get }
    /// One square: 32×32×3 floats, 0–255, interleaved.
    func code(_ square: UnsafeBufferPointer<Float>) -> Code256
}

extension NeighbourhoodMeasure {
    /// Every square in `squares` (count × 3072 floats).
    func codes(_ squares: [Float]) -> [Code256] {
        let n = CanonicalPatch.side * CanonicalPatch.side * 3
        let count = squares.count / n
        return squares.withUnsafeBufferPointer { all in
            (0..<count).map { code(UnsafeBufferPointer(rebasing: all[($0 * n)..<(($0 + 1) * n)])) }
        }
    }
}

/// The measures a seal can be read with, by name.
public enum NeighbourhoodMeasures {
    public static let names = ["hsl", "structure", "phase", "census"]

    public static func named(_ name: String, key: SealKey) -> (any NeighbourhoodMeasure)? {
        switch name {
        case "hsl": return HSLPattern(key: key)
        case "structure": return StructurePattern(key: key)
        case "phase": return PhasePattern(key: key)
        case "census": return CensusPattern(key: key)
        default: return nil
        }
    }
}
