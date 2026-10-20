//
//  SplitMix64.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The seeded generator every random choice in VeilGarde draws from: row subsamples and
//        column samples in the tree trainer, patch picks in the noiseprint sampler, token picks
//        for the semantic-tile head, the watermark acceptance crops.
//  PIN:  SplitMix64 (Steele, Lea and Flood), so a seed names one sequence on every machine and
//        in every build. A stream is derived as `SplitMix64(seed: seed ^ index)` rather than by
//        advancing a shared generator, so parallel work stays deterministic.
//

public struct SplitMix64: RandomNumberGenerator, Sendable {
    public var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A double in [0, 1) with 53 random bits.
    public mutating func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }

    /// A uniform index in 0..<n.
    public mutating func index(_ n: Int) -> Int {
        precondition(n > 0)
        return Int(next() % UInt64(n))
    }

    /// Fisher-Yates over `0..<n`.
    public mutating func permutation(_ n: Int) -> [Int] {
        var items = Array(0..<n)
        if n < 2 { return items }
        for i in stride(from: n - 1, to: 0, by: -1) { items.swapAt(i, index(i + 1)) }
        return items
    }
}
