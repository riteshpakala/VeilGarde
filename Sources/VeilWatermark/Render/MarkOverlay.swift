//
//  MarkOverlay.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The image that was read, as a person sees the result: scaled to at most 1,600 px, its tiles tinted
//        by agreement (green agrees, red does not, amber between, stronger where more was measured), the
//        signed image's extent drawn as an alignment box, an inset showing where the image sits on the
//        signed one, and a header with the verdict, the id, the pilots' z and the passive score.
//  PIN:  The layer: passive (the passive codes against the record, over the whole image) when there is a
//        match, else mark (the mark's levels against the id read, over the reading's window); auto takes
//        the first there is. Tiles are placed from the map's own origin, so the phase a reading found is
//        where the tint sits. The canvas is at least 640 px wide for the header.
//

import CoreGraphics
import Foundation

enum MarkOverlay {
    static let maxSide = 1600
    static let header = 64

    typealias P = RenderCanvas.Palette

    static func render(_ d: MarkDetection, query: CGImage, layer: OverlayLayer) throws -> Data {
        let scale = min(1, Double(maxSide) / Double(max(query.width, query.height)))
        let sw = max(1, Int((Double(query.width) * scale).rounded())), sh = max(1, Int((Double(query.height) * scale).rounded()))
        let canvas = try RenderCanvas(width: max(sw, 640), height: header + sh + 8)
        let x0 = (canvas.width - sw) / 2, y0 = header
        canvas.image(query, x: x0, y: y0, w: sw, h: sh)

        func px(_ v: Int) -> Int { Int((Double(v) * scale).rounded(.down)) }

        let map: TileMap?
        let shown: OverlayLayer
        switch layer {
        case .passive: map = d.agreement; shown = .passive
        case .mark: map = d.markMap; shown = .mark
        case .auto:
            if let agreement = d.agreement { map = agreement; shown = .passive } else { map = d.markMap; shown = .mark }
        }

        canvas.clip(x: x0, y: y0, w: sw, h: sh)
        if let map {
            for r in 0..<map.rows {
                for c in 0..<map.cols {
                    let (value, weight) = map[r, c]
                    guard weight > 0 else { continue }
                    let qx = map.originX + c * map.tile, qy = map.originY + r * map.tile
                    let x = px(qx), y = px(qy)
                    canvas.fill(x: x0 + x, y: y0 + y, w: max(1, px(qx + map.tile) - x), h: max(1, px(qy + map.tile) - y),
                                MarkDigest.tint(value), alpha: CGFloat(0.18 + 0.32 * Double(min(1, weight))))
                }
            }
        }
        // The signed image's extent, on this one.
        if let m = d.match, let record = d.record {
            let bx = px(-m.pixelX), by = px(-m.pixelY)
            canvas.outline(x: x0 + bx, y: y0 + by, w: max(4, px(record.width)), h: max(4, px(record.height)), P.accent, thickness: 2)
        }
        canvas.unclip()

        // Header: the verdict, then the numbers.
        canvas.fill(x: 0, y: 0, w: canvas.width, h: header, P.background)
        canvas.text(BitmapFont.fitted(d.verdict.words.uppercased(), pixels: canvas.width - 160, scale: 3), x: 16, y: 12, scale: 3, MarkDigest.color(of: d.verdict))
        var parts: [String] = []
        if let id = d.reading.id { parts.append("ID \(id.hex)") } else if let record = d.record { parts.append("ID \(record.id.hex) (PASSIVE)") }
        parts.append(String(format: "Z %.1f", d.reading.pilotZ))
        if let m = d.match { parts.append(String(format: "PASSIVE %.2f", m.score)) }
        if map != nil { parts.append("TINT \(shown == .passive ? "PASSIVE" : "MARK")") }
        canvas.text(BitmapFont.fitted(parts.joined(separator: " · "), pixels: canvas.width - 160, scale: 2), x: 16, y: 42, scale: 2, P.text)

        // Inset: the signed image, and where this one sits on it.
        if let m = d.match, let record = d.record, record.width > 0, record.height > 0 {
            let boxW = 112, boxH = 48
            let s = min(Double(boxW) / Double(record.width), Double(boxH) / Double(record.height))
            let iw = max(2, Int(Double(record.width) * s)), ih = max(2, Int(Double(record.height) * s))
            let ix = canvas.width - 16 - iw, iy = (header - ih) / 2
            canvas.fill(x: ix, y: iy, w: iw, h: ih, P.panel)
            canvas.outline(x: ix, y: iy, w: iw, h: ih, P.dim, thickness: 1)
            let fx = Int(Double(m.pixelX) * s), fy = Int(Double(m.pixelY) * s)
            let fw = max(2, Int(Double(d.width) * s)), fh = max(2, Int(Double(d.height) * s))
            canvas.clip(x: ix, y: iy, w: iw, h: ih)
            canvas.fill(x: ix + fx, y: iy + fy, w: fw, h: fh, P.accent, alpha: 0.6)
            canvas.unclip()
        }
        return try canvas.png()
    }
}
