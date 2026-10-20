//
//  PythonRandom.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: CPython's `random.Random`, exactly: MT19937 seeded the way `random.Random(int)` seeds it,
//        `getrandbits`, `_randbelow` and `shuffle`. The Python head trainers split sources and stems with
//        `random.Random(0).shuffle(...)`; with this, the Swift trainer splits the same rows the same
//        way, so a head trained here on the seed store is comparable coefficient for coefficient.
//  PIN:  CPython 3.12 `_randommodule.c` and `random.py`: an int seed n becomes init_by_array over
//        n's 32-bit words little-endian ([0] for 0); getrandbits(k ≤ 32) = genrand >> (32 − k);
//        _randbelow(n) draws getrandbits(n.bit_length()) until below n; shuffle walks i from the
//        end, j = _randbelow(i + 1). Checked against Python's own output
//        (Tests/VeilGardeTrainingTests/Fixtures/python_random.json).
//

public struct PythonRandom: Sendable {
    private var mt = [UInt32](repeating: 0, count: 624)
    private var index = 624

    public init(seed: UInt64) {
        var key: [UInt32] = []
        var n = seed
        repeat { key.append(UInt32(truncatingIfNeeded: n)); n >>= 32 } while n > 0
        initByArray(key)
    }

    private mutating func initGenrand(_ s: UInt32) {
        mt[0] = s
        for i in 1..<624 { mt[i] = 1_812_433_253 &* (mt[i - 1] ^ (mt[i - 1] >> 30)) &+ UInt32(i) }
        index = 624
    }

    private mutating func initByArray(_ key: [UInt32]) {
        initGenrand(19_650_218)
        var i = 1, j = 0
        for _ in 0..<max(624, key.count) {
            mt[i] = (mt[i] ^ ((mt[i - 1] ^ (mt[i - 1] >> 30)) &* 1_664_525)) &+ key[j] &+ UInt32(j)
            i += 1; j += 1
            if i >= 624 { mt[0] = mt[623]; i = 1 }
            if j >= key.count { j = 0 }
        }
        for _ in 0..<623 {
            mt[i] = (mt[i] ^ ((mt[i - 1] ^ (mt[i - 1] >> 30)) &* 1_566_083_941)) &- UInt32(i)
            i += 1
            if i >= 624 { mt[0] = mt[623]; i = 1 }
        }
        mt[0] = 0x8000_0000
        index = 624
    }

    public mutating func genrandUInt32() -> UInt32 {
        if index >= 624 {
            for k in 0..<624 {
                let y = (mt[k] & 0x8000_0000) | (mt[(k + 1) % 624] & 0x7FFF_FFFF)
                mt[k] = mt[(k + 397) % 624] ^ (y >> 1) ^ ((y & 1) != 0 ? 0x9908_B0DF : 0)
            }
            index = 0
        }
        var y = mt[index]
        index += 1
        y ^= y >> 11
        y ^= (y << 7) & 0x9D2C_5680
        y ^= (y << 15) & 0xEFC6_0000
        y ^= y >> 18
        return y
    }

    /// `random.getrandbits(k)` for 1 ≤ k ≤ 64.
    public mutating func getrandbits(_ k: Int) -> UInt64 {
        precondition(k >= 1 && k <= 64)
        if k <= 32 { return UInt64(genrandUInt32() >> UInt32(32 - k)) }
        var bits = k, value: UInt64 = 0, shift: UInt64 = 0
        while bits > 0 {
            var r = UInt64(genrandUInt32())
            if bits < 32 { r >>= UInt64(32 - bits) }
            value |= r << shift
            shift += 32
            bits -= 32
        }
        return value
    }

    /// `random._randbelow(n)` for n > 0.
    public mutating func randbelow(_ n: Int) -> Int {
        precondition(n > 0)
        let k = Int.bitWidth - n.leadingZeroBitCount
        var r = getrandbits(k)
        while r >= UInt64(n) { r = getrandbits(k) }
        return Int(r)
    }

    /// `random.shuffle(x)`.
    public mutating func shuffle<T>(_ x: inout [T]) {
        guard x.count > 1 else { return }
        for i in stride(from: x.count - 1, to: 0, by: -1) {
            let j = randbelow(i + 1)
            x.swapAt(i, j)
        }
    }

    /// `random.random()`: 53 bits from two draws.
    public mutating func random() -> Double {
        let a = Double(genrandUInt32() >> 5), b = Double(genrandUInt32() >> 6)
        return (a * 67_108_864.0 + b) * (1.0 / 9_007_199_254_740_992.0)
    }
}
