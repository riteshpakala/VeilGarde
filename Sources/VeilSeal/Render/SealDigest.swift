//
//  SealDigest.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A seal's digest: the picture as it was sealed with its anchors (gold) and the paths its
//        patterns walk (peach arrows), and beside it the seal's wax with the RR mark, its label, date,
//        id and what it holds. Without the picture, the panel stands alone over an empty frame.
//  PIN:  The same page as the detection graphic (SealGraphic): only the overlay and the lines differ.
//        At most 600 anchors are drawn, the strongest first.
//

import CoreGraphics
import Foundation

enum SealDigest {
    static func render(_ r: SealRecord, picture: CGImage?) throws -> Data {
        let (canvas, l) = try SealGraphic.page(picture: picture, width: r.image.width, height: r.image.height) { ctx, l in
            let unit = 1 / l.scale
            for path in r.paths {
                for h in 0..<path.hops.count {
                    let a = r.anchors[path.anchors[h]], b = r.anchors[path.anchors[h + 1]]
                    SealGraphic.arrow(ctx, from: SealPoint(Double(a.x), Double(a.y)), to: SealPoint(Double(b.x), Double(b.y)), width: 2 * unit,
                                      SealGraphic.peach, dashed: false, unit: unit)
                }
            }
            let strongest = r.anchors.sorted { $0.response > $1.response }.prefix(600)
            for a in strongest { SealGraphic.dot(ctx, Double(a.x), Double(a.y), radius: 2 * unit, SealGraphic.gold) }
        }
        var lines: [(String, RenderCanvas.RGB)] = []
        if let label = r.label { lines.append(("“\(label)”", RenderCanvas.Palette.text)) }
        lines.append(("Sealed \(SealGraphic.date.string(from: r.createdAt))", RenderCanvas.Palette.text))
        lines.append(("id \(r.id.hex)", RenderCanvas.Palette.dim))
        lines.append(("\(r.anchors.count) anchors · \(r.paths.count) paths · \(r.hopCount) hops", RenderCanvas.Palette.dim))
        lines.append(("\(r.image.width) × \(r.image.height)" + (r.interlace != nil ? " · interlaced" : ""), RenderCanvas.Palette.dim))
        lines.append((r.signature(limit: 34), RenderCanvas.Palette.dim))
        SealGraphic.panel(canvas, l, wax: try WaxSeal.image(id: r.id, size: 380), title: "sealed", titleColour: SealGraphic.rose, lines: lines)
        canvas.text("THE BURGUNDY SEAL", x: SealGraphic.margin, y: 18, scale: 2, SealGraphic.rose)
        canvas.text(BitmapFont.fitted((r.image.name ?? "").uppercased(), pixels: l.pictureW, scale: 2), x: SealGraphic.margin, y: 44, scale: 2,
                    RenderCanvas.Palette.dim)
        return try canvas.png()
    }
}
