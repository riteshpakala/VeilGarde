//
//  PayloadLayout.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Where the payload lives on the tile grid: a period of 15 × 16 tiles (480 × 512 px) repeated
//        from the image's top-left tile, holding 36 pilot cells of keyed level and the 204 coded bits,
//        interleaved and whitened by the key. Every tile carries one level, +1 or −1: its fragility
//        is pushed above or below its neighbours' of the other level. Reading tries the period at
//        every one of its 240 cyclic offsets, so a crop that starts anywhere still finds it.
//  PIN:  Tile (r, c) of the embedding grid is cell (r mod 15, c mod 16), row-major. Pilots are drawn by
//        the "pilots" stream, greedily, no two adjacent on the torus (8-neighbourhood); half +1, half
//        −1 by "pilot-levels". Data cells are the rest in row-major order; coded bit i sits in data
//        cell interleave[i] ("interleave") and its level is +1 exactly when bit ⊕ whiten[i] is 1
//        ("whiten"). A pilot's agreement is scored with Matcher.zScore over the hard signs it reads.
//

import Foundation

public struct PayloadLayout: Sendable, Equatable {
    public static let periodRows = 15
    public static let periodCols = 16
    public static let cells = periodRows * periodCols   // 240
    public static let pilotCount = 36
    public static let dataCount = cells - pilotCount    // 204 = PayloadCode.codedBits

    /// Pilot cell indices, ascending.
    public let pilotCells: [Int]
    /// Each pilot's level, in `pilotCells` order.
    public let pilotLevels: [Int8]
    /// The cell holding coded bit i.
    public let dataCells: [Int]
    /// The whitening bit XORed into coded bit i.
    public let whitening: [UInt8]

    public init(key: SealKey = .default) {
        precondition(Self.dataCount == PayloadCode.codedBits)
        var pilotGen = key.generator("pilots")
        var chosen: [Int] = []
        var blocked = Set<Int>()
        for cell in pilotGen.permutation(Self.cells) where !blocked.contains(cell) {
            chosen.append(cell)
            let (r, c) = (cell / Self.periodCols, cell % Self.periodCols)
            for dr in -1...1 {
                for dc in -1...1 { blocked.insert(Self.cell(row: r + dr, col: c + dc)) }
            }
            if chosen.count == Self.pilotCount { break }
        }
        precondition(chosen.count == Self.pilotCount, "the pilot draw ran out of room")
        pilotCells = chosen.sorted()
        var levelGen = key.generator("pilot-levels")
        let half = Self.pilotCount / 2
        pilotLevels = levelGen.permutation(Self.pilotCount).map { $0 < half ? 1 : -1 }
        let pilots = Set(pilotCells)
        let data = (0..<Self.cells).filter { !pilots.contains($0) }
        var interleaveGen = key.generator("interleave")
        dataCells = interleaveGen.permutation(Self.dataCount).map { data[$0] }
        var whitenGen = key.generator("whiten")
        whitening = (0..<Self.dataCount).map { _ in UInt8(whitenGen.next() & 1) }
    }

    /// The cell of tile (row, col) of a grid aligned to the period (negatives wrap).
    @inline(__always)
    public static func cell(row: Int, col: Int) -> Int {
        let r = ((row % periodRows) + periodRows) % periodRows
        let c = ((col % periodCols) + periodCols) % periodCols
        return r * periodCols + c
    }

    /// Every cell's level for a codeword of `PayloadCode.codedBits` bits.
    public func levels(codeword: [UInt8]) -> [Int8] {
        precondition(codeword.count == Self.dataCount)
        var out = [Int8](repeating: 0, count: Self.cells)
        for (i, cell) in pilotCells.enumerated() { out[cell] = pilotLevels[i] }
        for i in 0..<Self.dataCount { out[dataCells[i]] = (codeword[i] ^ whitening[i]) & 1 == 1 ? 1 : -1 }
        return out
    }

    /// Every cell's level for `id` under `key` (the key must be the layout's own).
    public func levels(for id: SealID, key: SealKey) -> [Int8] {
        levels(codeword: PayloadCode.encode(PayloadCode.message(id: id, key: key)))
    }

    // MARK: Reading

    /// A tile grid's soft levels folded onto the period's 240 positions, once: each position's
    /// weighted sum, and how many tiles there read positive and negative. Every cyclic offset reads
    /// from these, so trying all 240 costs 240 × 240 additions.
    public struct Folded: Sendable {
        public var sums = [Float](repeating: 0, count: PayloadLayout.cells)
        public var positives = [Int](repeating: 0, count: PayloadLayout.cells)
        public var negatives = [Int](repeating: 0, count: PayloadLayout.cells)

        /// `soft` and `weights` are row-major over `rows × cols`; tile (r, c) folds onto (r mod 15, c mod 16).
        public init(soft: [Float], weights: [Float], rows: Int, cols: Int) {
            for r in 0..<rows {
                for c in 0..<cols {
                    let i = r * cols + c
                    let s = soft[i]
                    guard s.isFinite, weights[i] > 0 else { continue }
                    let b = PayloadLayout.cell(row: r, col: c)
                    sums[b] += weights[i] * s
                    if s > 0 { positives[b] += 1 } else if s < 0 { negatives[b] += 1 }
                }
            }
        }
    }

    /// The bucket a cell reads from when tile (0, 0) sits at cyclic offset (row, col) of the period.
    @inline(__always)
    private static func bucket(cell: Int, offsetRow: Int, offsetCol: Int) -> Int {
        Self.cell(row: cell / periodCols - offsetRow, col: cell % periodCols - offsetCol)
    }

    /// How well the pilots agree at an offset: their hard signs against their levels.
    public func pilots(_ f: Folded, offsetRow: Int, offsetCol: Int) -> (z: Double, agreement: Double, bits: Int) {
        var agree = 0, total = 0
        for (i, cell) in pilotCells.enumerated() {
            let b = Self.bucket(cell: cell, offsetRow: offsetRow, offsetCol: offsetCol)
            agree += pilotLevels[i] > 0 ? f.positives[b] : f.negatives[b]
            total += f.positives[b] + f.negatives[b]
        }
        guard total > 0 else { return (0, 0, 0) }
        let score = Double(agree) / Double(total)
        return (Matcher.zScore(score: score, bits: total), score, total)
    }

    /// The coded bits' soft values at an offset, de-whitened (positive means 1).
    public func codedSoft(_ f: Folded, offsetRow: Int, offsetCol: Int) -> [Float] {
        (0..<Self.dataCount).map { i in
            let v = f.sums[Self.bucket(cell: dataCells[i], offsetRow: offsetRow, offsetCol: offsetCol)]
            return whitening[i] == 0 ? v : -v
        }
    }
}
