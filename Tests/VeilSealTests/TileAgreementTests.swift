//
//  TileAgreementTests.swift
//  VeilSealTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Where a match agrees, tile by tile: a grid against itself agrees everywhere it measured; a crop
//        read from the same fragility agrees at its offset and is weighted by what both measured; a tile
//        whose bits are flipped disagrees; tiles off the stored grid weigh nothing; the map's mean and
//        its placement on the image.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilSeal

@Suite("Tile agreement")
struct TileAgreementTests {
    static func fragility(rows: Int, cols: Int, seed: UInt64) -> FragilityGrid {
        var rng = SplitMix64(seed: seed)
        return FragilityGrid(rows: rows, cols: cols, values: (0..<(rows * cols)).map { _ in Float(rng.unit()) })
    }

    static func sub(_ g: FragilityGrid, r0: Int, c0: Int, rows: Int, cols: Int) -> FragilityGrid {
        var values: [Float] = []
        for r in r0..<(r0 + rows) { for c in c0..<(c0 + cols) { values.append(g[r, c]) } }
        return FragilityGrid(rows: rows, cols: cols, values: values)
    }

    @Test("a grid agrees with itself everywhere it measured, each tile weighted by its measured bits")
    func selfAgreement() {
        let codes = TileCodeGrid(Self.fragility(rows: 12, cols: 14, seed: 3))
        let map = Matcher.agreement(crop: codes, stored: codes, dx: 0, dy: 0)
        #expect(map.rows == 12 && map.cols == 14)
        for i in 0..<(12 * 14) {
            let measured = codes.masks[i].nonzeroBitCount
            #expect(map.weights[i] == Float(measured) / 4)
            if measured > 0 { #expect(map.values[i] == 1) }
        }
        #expect(map.meanValue == 1)
    }

    @Test("a crop agrees at its offset, is placed where it was read, and weighs nothing off the stored grid")
    func cropAgreement() {
        let stored = Self.fragility(rows: 20, cols: 20, seed: 9)
        let crop = TileCodeGrid(Self.sub(stored, r0: 5, c0: 7, rows: 8, cols: 9))
        let map = Matcher.agreement(crop: crop, stored: TileCodeGrid(stored), dx: 7, dy: 5, originX: 13, originY: 21)
        #expect(map.originX == 13 && map.originY == 21 && map.tile == 32)
        #expect(zip(map.values, map.weights).allSatisfy { $0.1 == 0 || $0.0 == 1 })
        #expect(Matcher.best(crop: crop, stored: TileCodeGrid(stored), minimumBits: 64).map { [$0.dx, $0.dy] } == [7, 5])
        // Off the grid: placed so that its last column hangs past the stored grid's edge.
        let off = Matcher.agreement(crop: crop, stored: TileCodeGrid(stored), dx: 12, dy: 5)
        for r in 0..<8 { #expect(off[r, 8].weight == 0) }
    }

    @Test("a tile with its bits flipped disagrees")
    func flipped() {
        let stored = TileCodeGrid(Self.fragility(rows: 6, cols: 6, seed: 4))
        var crop = stored
        let i = 2 * 6 + 3
        crop.bits[i] = ~crop.bits[i] & 0x0F
        let map = Matcher.agreement(crop: crop, stored: stored, dx: 0, dy: 0)
        #expect(map.values[i] == -1)
        #expect(map.meanValue < 1)
    }
}
