//
//  MarkDigest.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A mark's fingerprint as one 640 × 800 picture. For a record: its id, the 96 bits its pixels
//        carry (64 of id, 32 of CRC) as a 12 × 8 grid, and its signature's tile codes as a mosaic, each
//        tile a 2 × 2 of its four bits. For a detection: the verdict, the bits read against the record's,
//        the 204 coded bits' soft reads, and where the content agrees with the record, tile by tile.
//  PIN:  Drawn with integer rectangles and the bitmap font on an opaque canvas, so the same record is the
//        same pixels on every Mac (RenderTests pins one). Bit 1 is a filled cell, bit 0 an outlined one;
//        id bits orange, CRC bits amber; read against a record, green agrees and red does not. Mosaic:
//        a set bit light, an unset bit dark, a masked bit the panel; a grid too large for 2 × 2 cells draws
//        a tile as one cell, its brightness its share of set bits, and one too large even for that draws
//        every k-th tile.
//

import CoreGraphics
import Foundation

enum MarkDigest {
    static let width = 640
    static let height = 800
    static let margin = 24

    typealias P = RenderCanvas.Palette

    // MARK: A record

    static func record(_ record: SealRecord) throws -> Data {
        let canvas = try RenderCanvas(width: width, height: height)
        let inner = width - 2 * margin
        canvas.text("VEIL · VGM1 MARK", x: margin, y: margin, scale: 2, P.accent)
        canvas.text("WATERMARK", x: width - margin - BitmapFont.width("WATERMARK", scale: 2), y: margin, scale: 2, P.dim)
        canvas.text(record.id.hex, x: margin, y: 52, scale: 4, P.text)
        if let label = record.label, !label.isEmpty {
            canvas.text(BitmapFont.fitted("“\(label)”", pixels: inner, scale: 2), x: margin, y: 92, scale: 2, P.text)
        }
        let key = String(record.keyFingerprint.prefix(8)) + "…" + (record.keyFingerprint == SealKey.default.fingerprint ? " (DEFAULT)" : "")
        canvas.text(BitmapFont.fitted("CID \(record.cid.prefix(12))… · KEY \(key)", pixels: inner, scale: 2), x: margin, y: 114, scale: 2, P.dim)

        canvas.text("PAYLOAD · ID 64 + CRC-32C 32", x: margin, y: 146, scale: 2, P.dim)
        let bits = record.messageBits ?? []
        payloadGrid(canvas, y: 168) { i in
            guard i < bits.count else { return (P.masked, false) }
            return (i < PayloadCode.idBits ? P.accent : P.amber, bits[i] == 1)
        }

        let codes = record.signature.tileCodes
        canvas.text(BitmapFont.fitted("SIGNATURE · \(codes.cols) × \(codes.rows) TILES · \(grouped(codes.measuredBits)) BITS", pixels: inner, scale: 2),
                    x: margin, y: 392, scale: 2, P.dim)
        mosaic(canvas, codes, x: margin, y: 414, w: inner, h: 326)

        let report = record.report
        let verified = report.verified ? "VERIFIED" : "NOT VERIFIED"
        canvas.text(BitmapFont.fitted(String(format: "PSNR %.1f DB · L∞ %d · %@ · %d STEPS · %.0f S", report.psnr, report.linf, verified, report.steps, report.seconds),
                                      pixels: inner, scale: 2), x: margin, y: 756, scale: 2, report.verified ? P.text : P.disagree)
        canvas.text(BitmapFont.fitted("\(record.width) × \(record.height) · \(timestamp(record.createdAt))", pixels: inner, scale: 2),
                    x: margin, y: 776, scale: 2, P.dim)
        return try canvas.png()
    }

    // MARK: A detection

    static func detection(_ d: SealDetection) throws -> Data {
        let canvas = try RenderCanvas(width: width, height: height)
        let inner = width - 2 * margin
        canvas.text("VEIL · DETECTION", x: margin, y: margin, scale: 2, P.accent)
        canvas.text(BitmapFont.fitted(d.verdict.words.uppercased(), pixels: inner, scale: 4), x: margin, y: 52, scale: 4, color(of: d.verdict))

        let z = String(format: "%.1f", d.reading.pilotZ)
        let line: String
        if let id = d.reading.id {
            let agreement = d.reading.codewordAgreement.map { " · CODEWORD \(Int(($0 * 100).rounded()))%" } ?? ""
            line = "ID \(id.hex) · Z \(z)\(agreement)"
        } else {
            line = "NO ID READ · PILOT Z \(z) · \(d.reading.tiles) TILES"
        }
        canvas.text(BitmapFont.fitted(line, pixels: inner, scale: 2), x: margin, y: 92, scale: 2, P.text)
        let recorded: String
        if let record = d.record {
            let label = record.label.map { "“\($0)” · " } ?? ""
            recorded = "RECORDED AS \(label)\(record.id.short) · \(timestamp(record.createdAt))"
        } else {
            recorded = d.reading.id == nil ? "NOT FOUND IN THE STORE" : "THIS ID IS NOT IN THE STORE"
        }
        canvas.text(BitmapFont.fitted(recorded.uppercased(), pixels: inner, scale: 2), x: margin, y: 114, scale: 2, P.dim)

        // The 96 bits read, against the record's when there is one.
        let read = d.reading.message
        let expected = d.record?.messageBits
        let caption: String
        if expected != nil && d.reading.id != nil {
            caption = "PAYLOAD · READ AGAINST THE RECORD"
        } else if d.reading.id != nil {
            caption = "PAYLOAD · READ (CRC HOLDS)"
        } else {
            caption = "PAYLOAD · BEST GUESS (CRC FAILS)"
        }
        canvas.text(caption, x: margin, y: 146, scale: 2, P.dim)
        payloadGrid(canvas, y: 168) { i in
            guard i < read.count else { return (P.masked, false) }
            if let expected, d.reading.id != nil, i < expected.count {
                return (read[i] == expected[i] ? P.agree : P.disagree, read[i] == 1)
            }
            if d.reading.id != nil { return (i < PayloadCode.idBits ? P.accent : P.amber, read[i] == 1) }
            return (P.masked, read[i] == 1)
        }

        // The 204 coded bits' soft reads: four rows of 51.
        canvas.text("CODED BITS · \(PayloadCode.codedBits) SOFT READS", x: margin, y: 386, scale: 2, P.dim)
        codedStrip(canvas, d, y: 408)

        // Where the content agrees.
        let map: TileMap?
        let mapCaption: String
        if let agreement = d.agreement, let m = d.match {
            map = agreement
            mapCaption = String(format: "PASSIVE · %.2f AGREE AT (%d, %d) · %@ BITS", m.score, m.pixelX, m.pixelY, grouped(m.bitsCompared))
        } else if let markMap = d.markMap {
            map = markMap
            mapCaption = "MARK · WHERE THE LEVELS AGREE"
        } else {
            map = nil
            mapCaption = "PASSIVE · NO MATCH"
        }
        canvas.text(BitmapFont.fitted(mapCaption, pixels: inner, scale: 2), x: margin, y: 478, scale: 2, P.dim)
        canvas.fill(x: margin, y: 500, w: inner, h: 240, P.panel)
        if let map { tileMap(canvas, map, x: margin, y: 500, w: inner, h: 240) }

        canvas.text(BitmapFont.fitted(d.summary.uppercased(), pixels: inner, scale: 2), x: margin, y: 756, scale: 2, P.text)
        let key = d.keyFingerprint == SealKey.default.fingerprint ? "DEFAULT" : String(d.keyFingerprint.prefix(8)) + "…"
        canvas.text(BitmapFont.fitted(String(format: "%d × %d · READ IN %.1f S · KEY %@", d.width, d.height, d.seconds, key), pixels: inner, scale: 2),
                    x: margin, y: 776, scale: 2, P.dim)
        return try canvas.png()
    }

    static func color(of verdict: SealVerdict) -> RenderCanvas.RGB {
        switch verdict {
        case .marked: return P.agree
        case .contentMismatch: return P.disagree
        case .unknownID: return P.amber
        case .passiveMatch: return P.accent
        case .none: return P.dim
        }
    }

    // MARK: Parts

    /// The 96 message bits as 12 columns × 8 rows: `cell(i)` gives its colour and whether it is set.
    static func payloadGrid(_ canvas: RenderCanvas, y: Int, cell: (Int) -> (RenderCanvas.RGB, Bool)) {
        let cols = 12, cw = 44, ch = 22, gap = 4
        let x0 = (width - (cols * (cw + gap) - gap)) / 2
        for i in 0..<PayloadCode.messageBits {
            let x = x0 + (i % cols) * (cw + gap), yy = y + (i / cols) * (ch + gap)
            let (color, set) = cell(i)
            if set {
                canvas.fill(x: x, y: yy, w: cw, h: ch, color)
            } else {
                canvas.fill(x: x, y: yy, w: cw, h: ch, P.panel)
                canvas.outline(x: x, y: yy, w: cw, h: ch, color, thickness: 2)
            }
        }
    }

    /// The coded bits, four rows of 51: green or red by agreement with the id's codeword (grey with no id),
    /// stronger the larger the read.
    static func codedStrip(_ canvas: RenderCanvas, _ d: SealDetection, y: Int) {
        let soft = d.reading.codedSoft
        // The codeword the read is held to: the record's bits when there is one, else the message read (its CRC held).
        let codeword: [UInt8]? = {
            guard d.reading.id != nil else { return nil }
            if let bits = d.record?.messageBits { return PayloadCode.encode(bits) }
            return d.reading.message.count == PayloadCode.messageBits ? PayloadCode.encode(d.reading.message) : nil
        }()
        let peak = soft.map { abs($0) }.max() ?? 0
        let perRow = 51, cw = 10, ch = 12, gap = 1
        let x0 = (width - (perRow * (cw + gap) - gap)) / 2
        for i in 0..<PayloadCode.codedBits {
            let x = x0 + (i % perRow) * (cw + gap), yy = y + (i / perRow) * (ch + 2)
            canvas.fill(x: x, y: yy, w: cw, h: ch, P.panel)
            guard i < soft.count, peak > 0 else { continue }
            let strength = CGFloat(0.25 + 0.75 * Double(abs(soft[i]) / peak))
            let color: RenderCanvas.RGB
            if let codeword, i < codeword.count {
                color = (soft[i] > 0) == (codeword[i] == 1) ? P.agree : P.disagree
            } else {
                color = P.text
            }
            canvas.fill(x: x, y: yy, w: cw, h: ch, color, alpha: strength)
        }
    }

    /// Tile codes as a mosaic centred in the box.
    static func mosaic(_ canvas: RenderCanvas, _ codes: TileCodeGrid, x: Int, y: Int, w: Int, h: Int) {
        canvas.fill(x: x, y: y, w: w, h: h, P.panel)
        guard codes.rows > 0, codes.cols > 0 else { return }
        let on = P.text, off = RenderCanvas.RGB(r: 58, g: 63, b: 71)
        let fine = min(w / (2 * codes.cols), h / (2 * codes.rows))
        if fine >= 1 {
            let mw = 2 * codes.cols * fine, mh = 2 * codes.rows * fine
            let ox = x + (w - mw) / 2, oy = y + (h - mh) / 2
            // Bit k of a tile's nibble sits at (k % 2, k / 2) of its 2 × 2: E, S on top, SE, NE below.
            for r in 0..<codes.rows {
                for c in 0..<codes.cols {
                    let i = r * codes.cols + c
                    for k in 0..<4 where codes.masks[i] & (1 << k) != 0 {
                        canvas.fill(x: ox + (2 * c + k % 2) * fine, y: oy + (2 * r + k / 2) * fine, w: fine, h: fine,
                                    codes.bits[i] & (1 << k) != 0 ? on : off)
                    }
                }
            }
            return
        }
        let stride = max(1, Int((Double(max(codes.cols, 1)) / Double(w)).rounded(.up)), Int((Double(max(codes.rows, 1)) / Double(h)).rounded(.up)))
        let cols = codes.cols / stride, rows = codes.rows / stride
        let ox = x + (w - cols) / 2, oy = y + (h - rows) / 2
        for r in 0..<rows {
            for c in 0..<cols {
                let i = (r * stride) * codes.cols + c * stride
                let measured = codes.masks[i].nonzeroBitCount
                guard measured > 0 else { continue }
                let share = Double((codes.bits[i] & codes.masks[i]).nonzeroBitCount) / Double(measured)
                let level = UInt8(58 + (232 - 58) * share)
                canvas.fill(x: ox + c, y: oy + r, w: 1, h: 1, RenderCanvas.RGB(r: level, g: level, b: level))
            }
        }
    }

    /// A tile map in the box: green where it agrees, red where it does not, amber between; stronger where
    /// more was measured.
    static func tileMap(_ canvas: RenderCanvas, _ map: TileMap, x: Int, y: Int, w: Int, h: Int) {
        guard map.rows > 0, map.cols > 0 else { return }
        let size = max(1, min(w / map.cols, h / map.rows))
        let stride = size == 1 ? max(1, Int((Double(map.cols) / Double(w)).rounded(.up)), Int((Double(map.rows) / Double(h)).rounded(.up))) : 1
        let cols = map.cols / stride, rows = map.rows / stride
        let ox = x + (w - cols * size) / 2, oy = y + (h - rows * size) / 2
        for r in 0..<rows {
            for c in 0..<cols {
                let (value, weight) = map[r * stride, c * stride]
                guard weight > 0 else { continue }
                canvas.fill(x: ox + c * size, y: oy + r * size, w: size, h: size, tint(value), alpha: CGFloat(0.35 + 0.65 * Double(min(1, weight))))
            }
        }
    }

    static func tint(_ value: Float) -> RenderCanvas.RGB {
        value >= 0.5 ? P.agree : value <= -0.5 ? P.disagree : P.amber
    }

    static func grouped(_ n: Int) -> String {
        let digits = String(n)
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return out
    }

    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return f.string(from: date)
    }
}
