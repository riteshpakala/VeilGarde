//
//  MarkFixture.swift
//  VeilWatermarkTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What the pixel mark's tests share: soft tile levels laid by an id at a given period offset.
//

import Foundation
@testable import VeilWatermark

enum MarkFixture {
    static let id = WatermarkID(0x0123_4567_89ab_cdef)

    /// Soft levels (±1) on a rows × cols grid whose tile (0, 0) carries period cell (offsetRow, offsetCol).
    static func softGrid(id: WatermarkID, key: WatermarkKey = .default, rows: Int, cols: Int, offsetRow: Int, offsetCol: Int) -> [Float] {
        let levels = PayloadLayout(key: key).levels(for: id, key: key)
        var out = [Float](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            for c in 0..<cols { out[r * cols + c] = Float(levels[PayloadLayout.cell(row: r + offsetRow, col: c + offsetCol)]) }
        }
        return out
    }
}
