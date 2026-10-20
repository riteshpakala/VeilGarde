//
//  TileCodes.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The watermark's alphabet: for every tile, four ordinal bits saying whether its fragility
//        rate exceeds its forward neighbours' (east, south, south-east, north-east), with a mask
//        for the comparisons that fall outside the grid.
//  PIN:  Ordinal, so a monotone change of the residual's gain (a brighter print, a softer
//        re-encode) leaves the code alone. Bit k of a tile's nibble: 0 east, 1 south,
//        2 south-east, 3 north-east; an equal pair reads 0. A comparison is masked when the
//        neighbour is outside the grid, so a crop never compares against tiles it lacks.
//

public struct TileCodeGrid: Sendable, Equatable {
    public static let neighbours = [(0, 1), (1, 0), (1, 1), (-1, 1)]   // (dr, dc): E, S, SE, NE

    public var rows: Int
    public var cols: Int
    /// Per tile, its four bits in the low nibble.
    public var bits: [UInt8]
    /// Per tile, which of its four bits were measured.
    public var masks: [UInt8]

    public init(rows: Int, cols: Int, bits: [UInt8], masks: [UInt8]) {
        self.rows = rows
        self.cols = cols
        self.bits = bits
        self.masks = masks
    }

    public init(_ g: FragilityGrid) {
        rows = g.rows
        cols = g.cols
        bits = [UInt8](repeating: 0, count: g.rows * g.cols)
        masks = [UInt8](repeating: 0, count: g.rows * g.cols)
        for r in 0..<g.rows {
            for c in 0..<g.cols {
                let v = g[r, c]
                for (k, (dr, dc)) in Self.neighbours.enumerated() {
                    let nr = r + dr, nc = c + dc
                    guard nr >= 0, nr < g.rows, nc >= 0, nc < g.cols else { continue }
                    masks[r * g.cols + c] |= 1 << k
                    if v > g[nr, nc] { bits[r * g.cols + c] |= 1 << k }
                }
            }
        }
    }

    public var measuredBits: Int { masks.reduce(0) { $0 + $1.nonzeroBitCount } }

    /// The share of measured bits that are 1, per bit position.
    public var balance: [Double] {
        (0..<4).map { k in
            var ones = 0, total = 0
            for i in bits.indices where masks[i] & (1 << k) != 0 { total += 1; if bits[i] & (1 << k) != 0 { ones += 1 } }
            return total > 0 ? Double(ones) / Double(total) : .nan
        }
    }
}
