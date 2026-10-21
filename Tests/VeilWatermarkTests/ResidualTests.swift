//
//  ResidualTests.swift
//  VeilWatermarkTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The residual the watermark reads, held still. On the CPU: the sixteen corner moves (every
//        value, by digest) and the fixed probe's constants. On the GPU: each parity crop's fragility
//        rate at phase (0, 0) equals, value for value, what the detector's lens measured for it before
//        the residual moved into the watermark (column 0 of its feature dump), and its signature's
//        content id is the one pinned that day (2026-10-21).
//  PIN:  Exact equality, no tolerance: every signature ever written was read through this arithmetic,
//        so a change here is a change to the watermark. The invariance run over the battery's 105
//        images and the acceptance are the wider gates; this one runs with every test pass.
//

import CoreGraphics
import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeLens
@testable import VeilWatermark

@Suite("The residual's fixed probe")
struct ResidualConstantsTests {
    @Test("the sixteen corner moves are the literal table, every value")
    func displacements() {
        let table = WarpDisplacements.table
        #expect(table.count == 16 && table.allSatisfy { $0.count == 4 && $0.allSatisfy { $0.count == 2 } })
        #expect(table[0][0][0] == 0.5479120971119267 && table[15][3][1] == -0.7109516222679062)
        let joined = table.flatMap { $0.flatMap { $0 } }.map { "\($0)" }.joined(separator: ",")
        #expect(ContentHash.sha256Hex(Data(joined.utf8)) == "99493153cf79bb2478dbbf8b268e167d2f9d04fd081412ec9b6eac4a705b9143")
    }

    @Test("tiles of 32 px, 16 trials, a 9×9 high-pass at σ 1.5, strengths 0.025 and 0.05, 256 tiles an eval")
    func constants() {
        #expect(WarpConstants.tileSize == 32 && WarpConstants.trials == 16)
        #expect(WarpConstants.highPassKernel == 9 && WarpConstants.highPassSigma == 1.5)
        #expect(WarpConstants.lowStrength == 0.025 && WarpConstants.highStrength == 0.05)
        #expect(WarpConstants.evalTileBudget == 256)
    }
}

extension WatermarkMLXSuites {
    @Suite("The residual on the GPU", .serialized)
    struct ResidualOnGPU {
        @Test("each parity crop's fragility rate and signature are the pinned ones", arguments: ["crop_ben", "crop_fox"])
        func fragility(name: String) throws {
            let pinned = try Fixture.fragility(name)
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.crop(pinned.image))
            let grid = try NativePlane(cg).fragility()
            #expect(grid.rows == pinned.rows && grid.cols == pinned.cols)
            let want = pinned.fr.map { Float($0) }
            let worst = zip(grid.values, want).map { abs($0 - $1) }.max() ?? .infinity
            #expect(grid.values == want, "largest difference \(worst)")
            #expect(try Watermark.sign(cg).cid == pinned.cid)
        }
    }
}
