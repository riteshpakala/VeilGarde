//
//  WatermarkSignature.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: An image's watermark: its tile grid's size, its section words and their masks, and a
//        content id. Carried as JSON, as a compact binary, or as text ("vw1:" + base64url).
//  PIN:  Binary v1, little-endian: "VW1\0", version, tile (32), section (4), a zero byte, rows and
//        cols of the tile grid (u32 each), the section count (u32), the codes, the masks (u64
//        each). cid = SHA-256 of exactly those bytes, hex, so two signatures of the same pixels
//        are the same id. JSON writes the words as 16-digit hex (a 64-bit number is not safe in
//        every JSON reader).
//

import Foundation
import VeilGardeCore

public struct WatermarkSignature: Sendable, Equatable {
    public static let currentVersion = 1
    public static let magic = Data("VW1\0".utf8)

    public var version: Int
    public var tile: Int
    public var section: Int
    public var rows: Int
    public var cols: Int
    public var codes: [UInt64]
    public var masks: [UInt64]

    public init(grid: TileCodeGrid) {
        version = Self.currentVersion
        tile = WarpConstants.tileSize
        section = Sectioning.side
        rows = grid.rows
        cols = grid.cols
        (codes, masks) = Sectioning.pack(grid)
    }

    public init(version: Int = currentVersion, tile: Int = WarpConstants.tileSize, section: Int = Sectioning.side, rows: Int, cols: Int, codes: [UInt64], masks: [UInt64]) {
        self.version = version
        self.tile = tile
        self.section = section
        self.rows = rows
        self.cols = cols
        self.codes = codes
        self.masks = masks
    }

    public var tileCodes: TileCodeGrid { Sectioning.unpack(codes: codes, masks: masks, rows: rows, cols: cols) }

    public var measuredBits: Int { masks.reduce(0) { $0 + $1.nonzeroBitCount } }

    // MARK: Binary and text

    public var binary: Data {
        var d = Self.magic
        d.append(contentsOf: [UInt8(version), UInt8(tile), UInt8(section), 0])
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        u32(rows); u32(cols); u32(codes.count)
        for w in codes { withUnsafeBytes(of: w.littleEndian) { d.append(contentsOf: $0) } }
        for w in masks { withUnsafeBytes(of: w.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }

    public init(binary d: Data) throws {
        let b = [UInt8](d)
        guard b.count >= 20, Data(b[0..<4]) == Self.magic else { throw VeilGardeFailure.data("not a VW1 watermark signature") }
        func u32(_ at: Int) -> Int { Int(UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24) }
        func u64(_ at: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[at + $1]) << (8 * UInt64($1)) } }
        let n = u32(16)
        guard b.count == 20 + 16 * n else { throw VeilGardeFailure.data("a VW1 signature of \(n) sections must be \(20 + 16 * n) bytes, not \(b.count)") }
        let rows = u32(8), cols = u32(12)
        guard n == Sectioning.sectionRows(rows) * Sectioning.sectionCols(cols) else { throw VeilGardeFailure.data("a \(rows)×\(cols) grid has \(Sectioning.sectionRows(rows) * Sectioning.sectionCols(cols)) sections, not \(n)") }
        self.init(version: Int(b[4]), tile: Int(b[5]), section: Int(b[6]), rows: rows, cols: cols,
                  codes: (0..<n).map { u64(20 + 8 * $0) }, masks: (0..<n).map { u64(20 + 8 * (n + $0)) })
        guard version == Self.currentVersion, tile == WarpConstants.tileSize, section == Sectioning.side else { throw VeilGardeFailure.data("an unsupported watermark signature (version \(version), tile \(tile), section \(section))") }
    }

    public var cid: String { ContentHash.sha256Hex(binary) }

    public var compact: String {
        "vw1:" + binary.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public init(compact s: String) throws {
        guard s.hasPrefix("vw1:") else { throw VeilGardeFailure.data("a compact watermark starts with vw1:") }
        var b64 = String(s.dropFirst(4)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64) else { throw VeilGardeFailure.data("the watermark's base64url does not decode") }
        try self.init(binary: d)
    }
}

extension WatermarkSignature: Codable {
    enum CodingKeys: String, CodingKey { case version, tile, section, rows, cols, codes, masks, cid }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(tile, forKey: .tile)
        try c.encode(section, forKey: .section)
        try c.encode(rows, forKey: .rows)
        try c.encode(cols, forKey: .cols)
        try c.encode(codes.map { String(format: "%016llx", $0) }, forKey: .codes)
        try c.encode(masks.map { String(format: "%016llx", $0) }, forKey: .masks)
        try c.encode(cid, forKey: .cid)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func words(_ k: CodingKeys) throws -> [UInt64] {
            try c.decode([String].self, forKey: k).map {
                guard let w = UInt64($0, radix: 16) else { throw VeilGardeFailure.data("a watermark word \($0) is not hex") }
                return w
            }
        }
        self.init(version: try c.decode(Int.self, forKey: .version), tile: try c.decode(Int.self, forKey: .tile), section: try c.decode(Int.self, forKey: .section),
                  rows: try c.decode(Int.self, forKey: .rows), cols: try c.decode(Int.self, forKey: .cols), codes: try words(.codes), masks: try words(.masks))
        if let stated = try c.decodeIfPresent(String.self, forKey: .cid), stated != cid {
            throw VeilGardeFailure.data("the watermark's cid \(stated.prefix(12)) does not match its words (\(cid.prefix(12)))")
        }
    }
}
