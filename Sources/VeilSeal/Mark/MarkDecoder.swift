//
//  MarkDecoder.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Reading a pixel mark blind, with nothing but the key: the image's centre read on its own grid,
//        each tile's soft level from its log fragility against its neighbours', the period tried at all
//        240 cyclic offsets and the coded bits soft-decoded where the pilots stand out; then, for a crop,
//        a search for the exact pixel phase its grid sits at. A mark is read only when its CRC holds and
//        its pilots clear the z threshold.
//  PIN:  THE MARK LIVES ON THE EXACT TILE EDGES (measured 2026-11-17). A read 1 px off on one axis keeps
//        only the edges along the other (x off keeps the top and bottom, the stronger pair), and 1 px off
//        on both keeps nothing. So the search is separable: phase (0, 0) on the reading window, then every
//        y at x 0 and 16 (one of them within 8 px) and every x at the best y's, each read on the smaller
//        search window and tried for the CRC at once, then the best phases read again on the full window.
//        Every read that clears the threshold is a Viterbi try; over ~150 tries a random grid passes the
//        CRC and the pilots with probability ~1e-8.
//  PIN:  THE X SCAN RUNS AT THREE Y'S (measured 2026-11-17). The image's own content can outscore the
//        mark's y: on a 1900 × 900 crop of the composite, a peak at y 28 read z 4.65–5.05 whatever the id
//        (the pilots are the key's, not the id's), and for one id of four it beat the true y 5 (4.62),
//        though the exact phase decoded on both windows. So x is scanned at the best y and then at the
//        next best two more than 2 px from those before; an unmarked image pays 90 reads for it.
//  PIN:  THE PHASE IS POLISHED ONCE THE ID HOLDS (measured 2026-11-17). The scan stops at the first
//        phase whose CRC passes, which can sit 2 px off the exact one: a 1500 × 1000 crop of a photo at
//        (37, 91) passed at x 25, not 27, and the passive read there agreed 0.88 at (39, 91). With the id
//        known, so is every tile's level: the phases within 2 px on each axis (x first, then y at the
//        best x) are ranked by the codeword's soft correlation and the best is kept, 8 reads more. An
//        image found at (0, 0) on its first read is at its exact phase and pays nothing.
//  PIN:  A tile's soft level is the mean over its in-grid 8-neighbours of its log-fragility difference,
//        each clamped to ±clamp, weighted by clamp(σ/6, 0.2, 1) of its luma deviation. At the exact phase
//        about one tile in five reads the wrong way (on the parity composite), so a reading needs about
//        four periods folded (`minimumTiles`, ~1 MP) for the code to correct it.
//  PIN:  A session keeps every read's fragility, so detection matches the passive codes without reading
//        again.
//

import Foundation
import MLX
import VeilGardeLens

public struct MarkReading: Codable, Sendable, Equatable {
    /// The id the mark carries: set only when the CRC holds and the pilots clear the threshold.
    public var id: SealID?
    public var pilotZ: Double
    public var pilotAgreement: Double
    public var pilotBits: Int
    /// The grid phase the period was found at, in pixels.
    public var phaseX: Int
    public var phaseY: Int
    /// The period cell of tile (0, 0) of the image's grid at that phase.
    public var periodRow: Int
    public var periodCol: Int
    /// The 96 message bits decoded at the best offset, whether or not the CRC held.
    public var message: [UInt8]
    /// The 204 coded bits' soft values there (positive means 1).
    public var codedSoft: [Float]
    /// The share of coded bits whose sign agrees with the decoded id's codeword.
    public var codewordAgreement: Double?
    public var tiles: Int
    public var reads: Int
    public var seconds: Double

    public var found: Bool { id != nil }

    public static let empty = MarkReading(id: nil, pilotZ: 0, pilotAgreement: 0, pilotBits: 0, phaseX: 0, phaseY: 0, periodRow: 0, periodCol: 0,
                                          message: [], codedSoft: [], codewordAgreement: nil, tiles: 0, reads: 0, seconds: 0)
}

public enum MarkDecoder {
    /// The soft level that tints a tile of the mark map fully: the gap the embedder pushes a pair of levels to.
    static let mapScale: Float = 0.35

    /// The y's x is scanned at: the best of the y scan, and the next best apart from those before.
    static let scannedRows = 3

    /// How far apart two phases are on a period of `period` px.
    static func apart(_ a: Int, _ b: Int, period: Int) -> Int {
        let d = abs(a - b) % period
        return Swift.min(d, period - d)
    }

    /// The tiles a reading window needs at least: about four periods folded, which an image of ~1 MP holds.
    /// Fewer and one tile in five read wrong is more than the code corrects; an embed refuses such an image.
    public static let minimumTiles = 900

    /// One window read: its phase, where its first tile sits on the image, and its tiles' fragility.
    struct WindowRead {
        var phaseX: Int
        var phaseY: Int
        var grid: FragilityGrid
        var soft: [Float]
        var weights: [Float]
        var folded: PayloadLayout.Folded
        var scores: [(row: Int, col: Int, z: Double, agreement: Double, bits: Int)]
        var best: (row: Int, col: Int, z: Double, agreement: Double, bits: Int)
        /// Whether it read the reading window (the image's centre at its widest), not the search window.
        var full: Bool
    }

    /// What a reading leaves behind: the reading, every window read, and where the mark agrees.
    struct Session {
        var reading: MarkReading
        var reads: [WindowRead]
        /// Per window tile at the decoded offset: its soft level against the level the id lays there.
        var markMap: TileMap?
    }

    /// Reads `plane` blind under `key`.
    public static func read(_ plane: NativePlane, key: SealKey = .default, options: MarkReadOptions = .default) -> MarkReading {
        session(plane.array, width: plane.width, height: plane.height, key: key, options: options).reading
    }

    /// The window, at phase 0: its first tile and its size, leaving room for any phase up to 31 px.
    static func window(width: Int, height: Int, maxTiles: Int) -> (r0: Int, c0: Int, rows: Int, cols: Int) {
        let ts = WarpConstants.tileSize
        let rowsAvail = max(0, (height - (ts - 1)) / ts), colsAvail = max(0, (width - (ts - 1)) / ts)
        guard rowsAvail > 0, colsAvail > 0 else { return (0, 0, 0, 0) }
        var rows = rowsAvail, cols = colsAvail
        if rows * cols > maxTiles {
            rows = min(rowsAvail, max(1, Int((Double(maxTiles) * Double(rowsAvail) / Double(colsAvail)).squareRoot())))
            cols = min(colsAvail, max(1, maxTiles / rows))
            rows = min(rowsAvail, max(1, maxTiles / cols))
        }
        return ((rowsAvail - rows) / 2, (colsAvail - cols) / 2, rows, cols)
    }

    /// Each tile's soft level: the mean of its log-fragility differences from its in-grid 8-neighbours, each
    /// clamped to ±`clamp`.
    static func softLevels(_ fr: [Float], rows: Int, cols: Int, clamp: Float) -> [Float] {
        let g = fr.map(FragilityObjective.g)
        var out = [Float](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                var sum: Float = 0
                var n = 0
                for dr in -1...1 {
                    for dc in -1...1 where dr != 0 || dc != 0 {
                        let nr = r + dr, nc = c + dc
                        guard nr >= 0, nr < rows, nc >= 0, nc < cols else { continue }
                        sum += Swift.max(-clamp, Swift.min(clamp, g[r * cols + c] - g[nr * cols + nc]))
                        n += 1
                    }
                }
                out[r * cols + c] = n > 0 ? sum / Float(n) : 0
            }
        }
        return out
    }

    static func textureWeights(_ deviation: [Float]) -> [Float] { deviation.map { Swift.min(1, Swift.max(0.2, $0 / 6)) } }

    /// Every cyclic offset's pilot score for one folded read.
    static func score(_ folded: PayloadLayout.Folded, layout: PayloadLayout) -> [(row: Int, col: Int, z: Double, agreement: Double, bits: Int)] {
        var out: [(row: Int, col: Int, z: Double, agreement: Double, bits: Int)] = []
        out.reserveCapacity(PayloadLayout.cells)
        for row in 0..<PayloadLayout.periodRows {
            for col in 0..<PayloadLayout.periodCols {
                let p = layout.pilots(folded, offsetRow: row, offsetCol: col)
                out.append((row, col, p.z, p.agreement, p.bits))
            }
        }
        return out
    }

    /// The first candidate offset (z ≥ threshold, best z first) whose Viterbi output passes the CRC.
    static func decode(folded: PayloadLayout.Folded, layout: PayloadLayout, key: SealKey, threshold: Double,
                       scores: [(row: Int, col: Int, z: Double, agreement: Double, bits: Int)]) -> (id: SealID, row: Int, col: Int, message: [UInt8], soft: [Float])? {
        for candidate in scores.filter({ $0.z >= threshold }).sorted(by: { $0.z > $1.z }) {
            let soft = layout.codedSoft(folded, offsetRow: candidate.row, offsetCol: candidate.col)
            let message = PayloadCode.decode(soft)
            if let id = PayloadCode.id(fromMessage: message, key: key) { return (id, candidate.row, candidate.col, message, soft) }
        }
        return nil
    }

    /// One read of a window at a phase (0–31 px on each axis): each tile's fragility, soft level and texture
    /// weight, their fold onto the period, and every offset's pilot score.
    static func windowRead(_ plane: MLXArray, window w: (r0: Int, c0: Int, rows: Int, cols: Int), phaseX x: Int, phaseY y: Int,
                           layout: PayloadLayout, clamp: Float, full: Bool) -> WindowRead {
        let ts = WarpConstants.tileSize
        let ox = w.c0 * ts + x, oy = w.r0 * ts + y
        let fr = TileReads.fragility(plane, originX: ox, originY: oy, rows: w.rows, cols: w.cols)
        let weights = Self.textureWeights(TileReads.texture(plane, originX: ox, originY: oy, rows: w.rows, cols: w.cols))
        let soft = Self.softLevels(fr, rows: w.rows, cols: w.cols, clamp: clamp)
        let folded = PayloadLayout.Folded(soft: soft, weights: weights, rows: w.rows, cols: w.cols)
        let scores = Self.score(folded, layout: layout)
        return WindowRead(phaseX: x, phaseY: y, grid: FragilityGrid(rows: w.rows, cols: w.cols, values: fr, originX: ox, originY: oy),
                          soft: soft, weights: weights, folded: folded, scores: scores, best: scores.max(by: { $0.z < $1.z })!, full: full)
    }

    static func session(_ plane: MLXArray, width: Int, height: Int, key: SealKey, options: MarkReadOptions) -> Session {
        let start = Date()
        defer { LensRuntime.releaseMemory() }
        let ts = WarpConstants.tileSize
        let layout = PayloadLayout(key: key)
        let full = Self.window(width: width, height: height, maxTiles: options.windowTiles)
        guard full.rows * full.cols > 0 else { return Session(reading: .empty, reads: [], markMap: nil) }
        let small = Self.window(width: width, height: height, maxTiles: min(options.searchTiles, options.windowTiles))
        let searchWindow = small.rows * small.cols < full.rows * full.cols ? small : full
        let sameWindow = searchWindow == full
        var reads: [WindowRead] = []
        var found: (read: WindowRead, id: SealID, row: Int, col: Int, message: [UInt8], soft: [Float])?

        /// Reads a phase on the full window or the search window (once each), and tries it for the CRC.
        @discardableResult
        func read(_ px: Int, _ py: Int, wide: Bool) -> WindowRead {
            let x = ((px % ts) + ts) % ts, y = ((py % ts) + ts) % ts
            let isFull = wide || sameWindow
            if let done = reads.first(where: { $0.phaseX == x && $0.phaseY == y && $0.full == isFull }) { return done }
            let r = Self.windowRead(plane, window: isFull ? full : searchWindow, phaseX: x, phaseY: y, layout: layout,
                                    clamp: options.clamp, full: isFull)
            reads.append(r)
            if found == nil, r.best.z >= options.pilotThreshold,
               let hit = Self.decode(folded: r.folded, layout: layout, key: key, threshold: options.pilotThreshold, scores: r.scores) {
                found = (r, hit.id, hit.row, hit.col, hit.message, hit.soft)
            }
            return r
        }

        // Where an image marked whole keeps its mark, read as widely as the image allows.
        read(0, 0, wide: true)
        if found == nil, options.search {
            // Every y, at x 0 and 16: the top and bottom edges hold at the exact y while x is within 8 px.
            for y in 0..<ts {
                for x in [0, ts / 2] where found == nil { read(x, y, wide: false) }
                if found != nil { break }
            }
            if found == nil {
                var rows: [Int] = []
                for r in reads.filter({ !$0.full || sameWindow }).sorted(by: { $0.best.z > $1.best.z }) where rows.count < Self.scannedRows {
                    guard !rows.contains(where: { Self.apart($0, r.phaseY, period: ts) <= 2 }) else { continue }
                    rows.append(r.phaseY)
                }
                for y in rows where found == nil { for x in 0..<ts where found == nil { read(x, y, wide: false) } }
            }
            // The best phases again, on the full window: more periods folded than the search window holds.
            if found == nil, !sameWindow {
                var seen = Set<Int>()
                let best = reads.filter { !$0.full }.sorted { $0.best.z > $1.best.z }.filter { seen.insert($0.phaseY * ts + $0.phaseX).inserted }
                for r in best.prefix(3) where found == nil && r.best.z >= options.pilotThreshold { read(r.phaseX, r.phaseY, wide: true) }
            }
        }

        // The exact phase, once the id holds: the scan stopped at the first phase that passed.
        if let first = found, options.search, reads.count > 1 {
            let codeword = PayloadCode.encode(PayloadCode.message(id: first.id, key: key))
            /// The read's offset whose soft codeword agrees best with the id's, among those that clear the threshold
            /// and decode to it.
            func fit(_ r: WindowRead) -> (score: Float, row: Int, col: Int, message: [UInt8], soft: [Float])? {
                var best: (score: Float, row: Int, col: Int, message: [UInt8], soft: [Float])?
                for s in r.scores where s.z >= options.pilotThreshold {
                    let soft = layout.codedSoft(r.folded, offsetRow: s.row, offsetCol: s.col)
                    let score = zip(soft, codeword).reduce(Float(0)) { $0 + ($1.1 == 1 ? $1.0 : -$1.0) }
                    guard score > (best?.score ?? 0) else { continue }
                    let message = PayloadCode.decode(soft)
                    guard PayloadCode.id(fromMessage: message, key: key) == first.id else { continue }
                    best = (score, s.row, s.col, message, soft)
                }
                return best
            }
            var kept = (read: first.read, fit: fit(first.read))
            func consider(_ x: Int, _ y: Int) {
                let r = read(x, y, wide: first.read.full)
                if let f = fit(r), f.score > (kept.fit?.score ?? 0) { kept = (r, Optional(f)) }
            }
            for dx in [-2, -1, 1, 2] { consider(first.read.phaseX + dx, first.read.phaseY) }
            let x = kept.read.phaseX
            for dy in [-2, -1, 1, 2] { consider(x, first.read.phaseY + dy) }
            if let f = kept.fit { found = (kept.read, first.id, f.row, f.col, f.message, f.soft) }
        }

        let seconds = Date().timeIntervalSince(start)
        let tiles = full.rows * full.cols
        guard let f = found else {
            let best = reads.max(by: { $0.best.z < $1.best.z })!
            let soft = layout.codedSoft(best.folded, offsetRow: best.best.row, offsetCol: best.best.col)
            let (pr, pc) = Self.gridOffset(best.best.row, best.best.col, window: best.full ? full : searchWindow)
            let reading = MarkReading(id: nil, pilotZ: best.best.z, pilotAgreement: best.best.agreement, pilotBits: best.best.bits,
                                      phaseX: best.phaseX, phaseY: best.phaseY, periodRow: pr, periodCol: pc, message: PayloadCode.decode(soft),
                                      codedSoft: soft, codewordAgreement: nil, tiles: tiles, reads: reads.count, seconds: seconds)
            return Session(reading: reading, reads: reads, markMap: nil)
        }
        let w = f.read.full ? full : searchWindow
        let at = f.read.scores.first { $0.row == f.row && $0.col == f.col }!
        let codeword = PayloadCode.encode(PayloadCode.message(id: f.id, key: key))
        let agree = zip(f.soft, codeword).filter { ($0 > 0) == ($1 == 1) }.count
        let (pr, pc) = Self.gridOffset(f.row, f.col, window: w)
        let reading = MarkReading(id: f.id, pilotZ: at.z, pilotAgreement: at.agreement, pilotBits: at.bits, phaseX: f.read.phaseX,
                                  phaseY: f.read.phaseY, periodRow: pr, periodCol: pc, message: f.message, codedSoft: f.soft,
                                  codewordAgreement: Double(agree) / Double(codeword.count), tiles: tiles, reads: reads.count, seconds: seconds)
        let levels = layout.levels(codeword: codeword)
        var values = [Float](repeating: 0, count: w.rows * w.cols)
        for r in 0..<w.rows {
            for c in 0..<w.cols {
                let level = Float(levels[PayloadLayout.cell(row: r + f.row, col: c + f.col)])
                values[r * w.cols + c] = Swift.max(-1, Swift.min(1, f.read.soft[r * w.cols + c] * level / Self.mapScale))
            }
        }
        let map = TileMap(rows: w.rows, cols: w.cols, values: values, weights: f.read.weights, originX: f.read.grid.originX, originY: f.read.grid.originY)
        return Session(reading: reading, reads: reads, markMap: map)
    }

    /// The period cell of the phase grid's tile (0, 0), when the window starting at its tile (r0, c0) reads offset (row, col).
    static func gridOffset(_ row: Int, _ col: Int, window w: (r0: Int, c0: Int, rows: Int, cols: Int)) -> (Int, Int) {
        (((row - w.r0) % PayloadLayout.periodRows + PayloadLayout.periodRows) % PayloadLayout.periodRows,
         ((col - w.c0) % PayloadLayout.periodCols + PayloadLayout.periodCols) % PayloadLayout.periodCols)
    }
}
