//
//  PayloadLayoutTests.swift
//  VeilSealTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The payload's place on the tiles, on the CPU: the period's constants, the pilots (36, no two
//        adjacent on the torus, half each level), the interleaver a permutation of the data cells, the
//        default key's derivation and an id's levels pinned by digest; a clean grid read back at every
//        one of the 240 cyclic offsets; and 2,000 random grids, none accepted, their pilot z near N(0, 1).
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilSeal

@Suite("The payload layout")
struct PayloadLayoutTests {
    let layout = PayloadLayout(key: .default)

    @Test("a 15 × 16 period: 240 cells, 36 pilots, 204 data cells, the code's 204 bits")
    func constants() {
        #expect(PayloadLayout.periodRows == 15 && PayloadLayout.periodCols == 16 && PayloadLayout.cells == 240)
        #expect(PayloadLayout.pilotCount == 36 && PayloadLayout.dataCount == 204 && PayloadLayout.dataCount == PayloadCode.codedBits)
        #expect(PayloadLayout.cell(row: -1, col: -1) == 14 * 16 + 15)
        #expect(PayloadLayout.cell(row: 15, col: 16) == 0)
    }

    @Test("pilots: distinct, no two adjacent on the torus, eighteen of each level; data: the other cells, each once")
    func pilotsAndData() {
        #expect(Set(layout.pilotCells).count == 36 && layout.pilotCells == layout.pilotCells.sorted())
        for a in layout.pilotCells {
            let (r, c) = (a / 16, a % 16)
            for dr in -1...1 {
                for dc in -1...1 where dr != 0 || dc != 0 {
                    #expect(!layout.pilotCells.contains(PayloadLayout.cell(row: r + dr, col: c + dc)), "pilots \(a) and a neighbour")
                }
            }
        }
        #expect(layout.pilotLevels.filter { $0 == 1 }.count == 18 && layout.pilotLevels.filter { $0 == -1 }.count == 18)
        #expect(Set(layout.dataCells).count == 204)
        #expect(Set(layout.dataCells).isDisjoint(with: layout.pilotCells))
        #expect(Set(layout.dataCells).union(layout.pilotCells) == Set(0..<240))
        #expect(layout.whitening.count == 204)
        // Another key lays another pattern.
        #expect(PayloadLayout(key: SealKey(phrase: "another key")) != layout)
    }

    @Test("the default key and an id's levels are the pinned ones")
    func pinned() {
        #expect(SealKey.default.fingerprint == "de7a4acd068a956b")
        let levels = layout.levels(for: MarkFixture.id, key: .default)
        #expect(levels.count == 240 && levels.allSatisfy { $0 == 1 || $0 == -1 })
        #expect(ContentHash.sha256Hex(Data(levels.map { UInt8(bitPattern: $0) })) == "920289c356237250a77e25825855d612c61c34a18b58b016af8700438a233ab4")
        // Roughly balanced, so a mark moves as many tiles up as down.
        let up = levels.filter { $0 == 1 }.count
        #expect(abs(up - 120) <= 24, "\(up) of 240 up")
    }

    @Test("a clean grid reads back its id at every one of the 240 cyclic offsets")
    func everyOffset() {
        let rows = 30, cols = 32
        let weights = [Float](repeating: 1, count: rows * cols)
        for oR in 0..<15 {
            for oC in 0..<16 {
                let soft = MarkFixture.softGrid(id: MarkFixture.id, rows: rows, cols: cols, offsetRow: oR, offsetCol: oC)
                let folded = PayloadLayout.Folded(soft: soft, weights: weights, rows: rows, cols: cols)
                let scores = MarkDecoder.score(folded, layout: layout)
                let best = scores.max { $0.z < $1.z }!
                #expect(best.row == oR && best.col == oC, "offset (\(oR), \(oC)) scored best at (\(best.row), \(best.col))")
                let hit = MarkDecoder.decode(folded: folded, layout: layout, key: .default, threshold: 3, scores: scores)
                #expect(hit?.id == MarkFixture.id && hit?.row == oR && hit?.col == oC, "offset (\(oR), \(oC))")
            }
        }
    }

    @Test("2,000 random grids: no reading accepted, and the pilots' z sits near N(0, 1)")
    func randomGridsNeverRead() {
        var rng = SplitMix64(seed: 2026_1117)
        let rows = 32, cols = 32
        let weights = [Float](repeating: 1, count: rows * cols)
        var accepted = 0, samples = 0
        var sum = 0.0, squares = 0.0
        for _ in 0..<2000 {
            let soft = (0..<(rows * cols)).map { _ in Float(rng.unit() * 2 - 1) }
            let folded = PayloadLayout.Folded(soft: soft, weights: weights, rows: rows, cols: cols)
            let scores = MarkDecoder.score(folded, layout: layout)
            for s in scores {
                sum += s.z
                squares += s.z * s.z
                samples += 1
            }
            if MarkDecoder.decode(folded: folded, layout: layout, key: .default, threshold: 3, scores: scores) != nil { accepted += 1 }
        }
        let mean = sum / Double(samples), sd = (squares / Double(samples) - mean * mean).squareRoot()
        #expect(accepted == 0)
        #expect(abs(mean) < 0.05, "mean z \(mean)")
        #expect(sd > 0.85 && sd < 1.15, "sd of z \(sd)")
    }

    @Test("a soft level is the mean of the clamped log-fragility differences from the in-grid neighbours; texture weights clamp to 0.2…1")
    func softLevelsAndWeights() {
        // One bright tile in a flat 3 × 3: its level is g(4) − g(1), its neighbours' the negative shared over their neighbours.
        var fr = [Float](repeating: 1, count: 9)
        fr[4] = 4
        let soft = MarkDecoder.softLevels(fr, rows: 3, cols: 3, clamp: 2)
        let step = Float(log(4.05) - log(1.05))
        #expect(abs(soft[4] - step) < 1e-5)
        #expect(abs(soft[0] - (-step / 3)) < 1e-5, "a corner has 3 neighbours, one of them bright")
        #expect(abs(soft[1] - (-step / 5)) < 1e-5, "an edge has 5")
        fr[4] = 40
        #expect(abs(MarkDecoder.softLevels(fr, rows: 3, cols: 3, clamp: 2)[4] - 2) < 1e-5, "a difference past the clamp counts as the clamp")
        #expect(MarkDecoder.textureWeights([0, 1, 3, 6, 20]) == [0.2, 0.2, 0.5, 1, 1])
    }

    @Test("the window: at most the budget, centred, leaving room for a 31-px phase; phases apart on the period")
    func window() {
        #expect(MarkDecoder.apart(28, 5, period: 32) == 9 && MarkDecoder.apart(31, 1, period: 32) == 2 && MarkDecoder.apart(7, 7, period: 32) == 0)
        let w = MarkDecoder.window(width: 4032, height: 3024, maxTiles: 1024)
        #expect(w.rows * w.cols <= 1024 && w.rows * w.cols > 900)
        #expect((w.c0 + w.cols) * 32 + 31 <= 4032 && (w.r0 + w.rows) * 32 + 31 <= 3024)
        #expect(abs(w.c0 - (125 - w.cols) / 2) <= 1 && abs(w.r0 - (93 - w.rows) / 2) <= 1)
        let small = MarkDecoder.window(width: 512, height: 512, maxTiles: 1024)
        #expect(small.rows == 15 && small.cols == 15 && small.r0 == 0 && small.c0 == 0)
        #expect(MarkDecoder.window(width: 40, height: 40, maxTiles: 1024).rows == 0)
    }
}
