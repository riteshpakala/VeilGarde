//
//  PayloadCodeTests.swift
//  VeilSealTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The payload's code on the CPU: CRC-32C's check value, the 96-bit message (id then CRC over
//        the key's fingerprint and the id), the terminated K = 7 rate-½ encoder, the soft Viterbi on a
//        clean codeword, with 30% of it erased and with noise, and the CRC refusing a wrong bit or key.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilSeal

@Suite("The payload code")
struct PayloadCodeTests {
    static func soft(_ codeword: [UInt8]) -> [Float] { codeword.map { $0 == 1 ? 1 : -1 } }

    @Test("CRC-32C of \"123456789\" is its check value 0xE3069283")
    func crcCheckValue() {
        #expect(PayloadCode.crc32c(Array("123456789".utf8)) == 0xE306_9283)
        #expect(PayloadCode.crc32c([]) == 0)
    }

    @Test("the message is the id's 64 bits, most significant first, then the CRC of fingerprint ‖ id")
    func message() {
        let key = SealKey.default
        let m = PayloadCode.message(id: MarkFixture.id, key: key)
        #expect(m.count == PayloadCode.messageBits && PayloadCode.messageBits == 96)
        #expect(Array(m.prefix(64)) == MarkFixture.id.bits)
        let crc = PayloadCode.crc32c(key.fingerprintBytes + MarkFixture.id.bytes)
        #expect(Array(m.suffix(32)) == (0..<32).map { UInt8((crc >> UInt32(31 - $0)) & 1) })
        #expect(PayloadCode.fingerprintBytes(key.fingerprint) == key.fingerprintBytes)
        #expect(PayloadCode.fingerprintBytes("not hex") == nil)
        #expect(PayloadCode.message(id: MarkFixture.id, fingerprint: key.fingerprintBytes) == m)
    }

    @Test("the encoder writes 204 bits, two per input, and ends in state zero")
    func encoder() {
        let m = PayloadCode.message(id: MarkFixture.id, key: .default)
        let c = PayloadCode.encode(m)
        #expect(c.count == PayloadCode.codedBits && PayloadCode.codedBits == 204)
        // An all-zero message encodes to all zeros (the code is linear), and a single 1 to the generators' taps.
        #expect(PayloadCode.encode([UInt8](repeating: 0, count: 96)).allSatisfy { $0 == 0 })
        let impulse = PayloadCode.encode([1] + [UInt8](repeating: 0, count: 95))
        #expect(impulse.reduce(0) { $0 + Int($1) } == 10, "the free distance of (171, 133) is 10")
    }

    @Test("Viterbi recovers the message from a clean codeword, with 30% erased, and through noise")
    func viterbi() {
        for seed in UInt64(1)...20 {
            var rng = SplitMix64(seed: seed)
            let id = SealID(rng.next())
            let m = PayloadCode.message(id: id, key: .default)
            let c = Self.soft(PayloadCode.encode(m))
            #expect(PayloadCode.decode(c) == m)
            // 30% erased, at random.
            var erased = c
            for i in rng.permutation(c.count).prefix(c.count * 3 / 10) { erased[i] = 0 }
            #expect(PayloadCode.decode(erased) == m, "seed \(seed): 30% erased")
            // Gaussian noise of σ 0.6 on every soft bit (about 5% of signs flipped).
            let noisy = c.map { v -> Float in
                let u1 = max(rng.unit(), 1e-12), u2 = rng.unit()
                return v + Float(0.6 * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
            }
            #expect(PayloadCode.decode(noisy) == m, "seed \(seed): noise")
        }
    }

    @Test("the CRC refuses a flipped bit and another key's fingerprint")
    func crcRefuses() throws {
        let key = SealKey.default
        let m = PayloadCode.message(id: MarkFixture.id, key: key)
        #expect(PayloadCode.id(fromMessage: m, key: key) == MarkFixture.id)
        for i in [0, 31, 63, 64, 95] {
            var bad = m
            bad[i] ^= 1
            #expect(PayloadCode.id(fromMessage: bad, key: key) == nil, "bit \(i)")
        }
        #expect(PayloadCode.id(fromMessage: m, key: SealKey(phrase: "another key")) == nil)
        #expect(PayloadCode.id(fromMessage: Array(m.prefix(95)), key: key) == nil)
    }

    @Test("ids: hex both ways, short form, bytes big-endian; keys: phrase, bytes, hex file, fingerprint")
    func idsAndKeys() throws {
        #expect(MarkFixture.id.hex == "0123456789abcdef")
        #expect(SealID(hex: "0123456789ABCDEF") == MarkFixture.id)
        #expect(SealID(hex: "0123") == nil && SealID(hex: "zz23456789abcdef") == nil)
        #expect(MarkFixture.id.short == "0123…")
        #expect(MarkFixture.id.bytes == [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef])
        let json = try JSONEncoder().encode([MarkFixture.id])
        #expect(String(decoding: json, as: UTF8.self) == "[\"0123456789abcdef\"]")
        #expect(try JSONDecoder().decode([SealID].self, from: json) == [MarkFixture.id])

        #expect(SealKey.default.bytes == ContentHash.sha256Bytes(Data(SealKey.defaultPhrase.utf8)))
        #expect(SealKey.default.isDefault && !SealKey(phrase: "x").isDefault)
        #expect(throws: (any Error).self) { _ = try SealKey(bytes: [1, 2, 3]) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vgm1-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hexFile = folder.appendingPathComponent("k.hex")
        try (SealKey.default.bytes.map { String(format: "%02x", $0) }.joined() + "\n").write(to: hexFile, atomically: true, encoding: .utf8)
        #expect(try SealKey(contentsOf: hexFile) == .default)
        let rawFile = folder.appendingPathComponent("k.bin")
        try Data(SealKey.default.bytes).write(to: rawFile)
        #expect(try SealKey(contentsOf: rawFile) == .default)
        #expect(SealKey.default.fingerprint.count == 16)
    }
}
