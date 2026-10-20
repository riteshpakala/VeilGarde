//
//  Sectioning.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: How tile codes are kept: the grid cut into sections of 4×4 tiles (128 px), each a 64-bit
//        word of its sixteen nibbles in row-major tile order, with a 64-bit mask beside it, the
//        sections themselves in row-major order. A crop contains whole sections of the image it
//        came from, and the concatenation of section words is the signature.
//  PIN:  No hash folds the tiles: a section word keeps every tile's nibble in place, so a bit
//        that differs is one bit of Hamming distance, not a different hash. Tiles past the
//        grid's edge in a border section are masked.
//

public enum Sectioning {
    public static let side = 4

    public static func sectionRows(_ rows: Int) -> Int { (rows + side - 1) / side }
    public static func sectionCols(_ cols: Int) -> Int { (cols + side - 1) / side }

    public static func pack(_ g: TileCodeGrid) -> (codes: [UInt64], masks: [UInt64]) {
        let sr = sectionRows(g.rows), sc = sectionCols(g.cols)
        var codes = [UInt64](repeating: 0, count: sr * sc), masks = [UInt64](repeating: 0, count: sr * sc)
        for r in 0..<g.rows {
            for c in 0..<g.cols {
                let s = (r / side) * sc + c / side
                let k = UInt64(((r % side) * side + c % side) * 4)
                codes[s] |= UInt64(g.bits[r * g.cols + c] & 0xF) << k
                masks[s] |= UInt64(g.masks[r * g.cols + c] & 0xF) << k
            }
        }
        return (codes, masks)
    }

    public static func unpack(codes: [UInt64], masks: [UInt64], rows: Int, cols: Int) -> TileCodeGrid {
        let sc = sectionCols(cols)
        var bits = [UInt8](repeating: 0, count: rows * cols), m = [UInt8](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                let s = (r / side) * sc + c / side
                let k = UInt64(((r % side) * side + c % side) * 4)
                bits[r * cols + c] = UInt8((codes[s] >> k) & 0xF)
                m[r * cols + c] = UInt8((masks[s] >> k) & 0xF)
            }
        }
        return TileCodeGrid(rows: rows, cols: cols, bits: bits, masks: m)
    }
}
