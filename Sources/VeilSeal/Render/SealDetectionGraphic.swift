//
//  SealDetectionGraphic.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The pictures a seal is shown with. A detection: the found picture with the seal's paths walked
//        across it (gold anchors the two pictures share, peach arrows for hops retraced, faint dashes
//        for hops not), the original's outline where it sits, and beside it the wax seal stamped
//        (sealed) or its ghost (no seal) over the verdict, label, date, coverage and hops. A seal's
//        digest (SealDigest) is the same page for the picture as it was sealed.
//  PIN:  The picture is scaled down to fit 1000 × 760, never up but for small ones (to a 520-px side); the panel is 440 px
//        wide; lines, dots and the outline are antialiased, text is the bitmap font. Colours: gold
//        #E3B341, peach #F4B183, rose #E06C88 on #121418.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens

enum SealGraphic {
    static let gold = RenderCanvas.RGB(r: 0xE3, g: 0xB3, b: 0x41)
    static let peach = RenderCanvas.RGB(r: 0xF4, g: 0xB1, b: 0x83)
    static let rose = RenderCanvas.RGB(r: 0xE0, g: 0x6C, b: 0x88)
    static let ink = RenderCanvas.RGB(r: 0x12, g: 0x14, b: 0x18)
    static let margin = 32
    static let panel = 440
    static let header = 92

    struct Layout {
        var pictureW: Int
        var pictureH: Int
        var scale: Double
        var width: Int { margin + pictureW + margin + panel }
        var height: Int { header + max(pictureH, 620) + margin }
    }

    static func layout(width: Int, height: Int) -> Layout {
        let w = Double(max(1, width)), h = Double(max(1, height))
        var s = min(1, 1000 / w, 760 / h)
        if max(w, h) * s < 520 { s = 520 / max(w, h) }
        return Layout(pictureW: max(1, Int((w * s).rounded())), pictureH: max(1, Int((h * s).rounded())), scale: s)
    }

    /// Draws `picture` at the left with `draw` over it in picture pixels, and returns the canvas.
    static func page(picture: CGImage?, width: Int, height: Int, draw: (CGContext, Layout) -> Void) throws -> (RenderCanvas, Layout) {
        let l = layout(width: width, height: height)
        let canvas = try RenderCanvas(width: l.width, height: l.height, background: ink)
        canvas.fill(x: margin - 1, y: header - 1, w: l.pictureW + 2, h: l.pictureH + 2, RenderCanvas.Palette.off)
        if let picture { canvas.image(picture, x: margin, y: header, w: l.pictureW, h: l.pictureH) }
        let ctx = canvas.context
        ctx.saveGState()
        ctx.clip(to: CGRect(x: margin, y: header, width: l.pictureW, height: l.pictureH))
        ctx.setShouldAntialias(true)
        ctx.translateBy(x: CGFloat(margin), y: CGFloat(header))
        ctx.scaleBy(x: CGFloat(l.scale), y: CGFloat(l.scale))
        draw(ctx, l)
        ctx.restoreGState()
        return (canvas, l)
    }

    static func dot(_ ctx: CGContext, _ x: Double, _ y: Double, radius r: Double, _ colour: RenderCanvas.RGB) {
        ctx.setFillColor(ink.cg(0.85))
        ctx.fillEllipse(in: CGRect(x: x - r - 1, y: y - r - 1, width: 2 * r + 2, height: 2 * r + 2))
        ctx.setFillColor(colour.cg())
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }

    static func arrow(_ ctx: CGContext, from a: SealPoint, to b: SealPoint, width: Double, _ colour: RenderCanvas.RGB, dashed: Bool, unit: Double) {
        ctx.setStrokeColor(colour.cg(dashed ? 0.45 : 0.95))
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: dashed ? [3 * unit, 4 * unit] : [])
        let dx = b.x - a.x, dy = b.y - a.y, d = max(1e-6, hypot(dx, dy))
        let ux = dx / d, uy = dy / d
        let head = min(d * 0.45, 9 * unit)
        let end = SealPoint(b.x - ux * 4 * unit, b.y - uy * 4 * unit)
        ctx.move(to: CGPoint(x: a.x + ux * 4 * unit, y: a.y + uy * 4 * unit))
        ctx.addLine(to: CGPoint(x: end.x, y: end.y))
        ctx.strokePath()
        guard !dashed else { return }
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setFillColor(colour.cg(0.95))
        ctx.move(to: CGPoint(x: end.x, y: end.y))
        ctx.addLine(to: CGPoint(x: end.x - ux * head - uy * head * 0.5, y: end.y - uy * head + ux * head * 0.5))
        ctx.addLine(to: CGPoint(x: end.x - ux * head + uy * head * 0.5, y: end.y - uy * head - ux * head * 0.5))
        ctx.closePath()
        ctx.fillPath()
    }

    static func outline(_ ctx: CGContext, _ corners: [SealPoint], unit: Double) {
        guard corners.count >= 3 else { return }
        ctx.setStrokeColor(rose.cg(0.95))
        ctx.setLineWidth(2.5 * unit)
        ctx.setLineDash(phase: 0, lengths: [10 * unit, 6 * unit])
        ctx.move(to: CGPoint(x: corners[0].x, y: corners[0].y))
        for p in corners.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
        ctx.closePath()
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    /// The panel at the right: the wax (or its ghost), then lines of text.
    static func panel(_ canvas: RenderCanvas, _ l: Layout, wax: CGImage, title: String, titleColour: RenderCanvas.RGB, lines: [(String, RenderCanvas.RGB)]) {
        let x = margin + l.pictureW + margin
        canvas.text(BitmapFont.fitted(title.uppercased(), pixels: panel - 16, scale: 4), x: x, y: 30, scale: 4, titleColour)
        canvas.context.saveGState()
        canvas.context.setShouldAntialias(true)
        canvas.image(wax, x: x + 20, y: header - 16, w: 380, h: 380)
        canvas.context.restoreGState()
        var y = header + 380
        for (line, colour) in lines {
            canvas.text(BitmapFont.fitted(line.uppercased(), pixels: panel - 24, scale: 2), x: x + 8, y: y, scale: 2, colour)
            y += 24
        }
        canvas.text(BitmapFont.fitted(BurgundySeal.motto.uppercased(), pixels: panel - 24, scale: 1), x: x + 8, y: l.height - margin - 4, scale: 1,
                    RenderCanvas.Palette.dim)
    }

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// A detection drawn over the picture it read.
    static func detection(_ d: SealDetection, picture: CGImage?) throws -> Data {
        let (canvas, l) = try page(picture: picture, width: d.width, height: d.height) { ctx, l in
            guard let m = d.match else { return }
            let unit = 1 / l.scale
            if m.found || d.verdict != .none {
                for trail in m.trails {
                    for h in 0..<trail.retraced.count {
                        guard let a = trail.points[h], let b = trail.points[h + 1], let ok = trail.retraced[h] else { continue }
                        arrow(ctx, from: a, to: b, width: (ok ? 2.4 : 1.4) * unit, ok ? peach : RenderCanvas.Palette.dim, dashed: !ok, unit: unit)
                    }
                }
                for p in m.anchors.prefix(600) { dot(ctx, p.x, p.y, radius: 2.4 * unit, gold) }
                outline(ctx, m.portion, unit: unit)
            }
        }
        let sealed = d.verdict == .sealed || d.verdict == .interlaceOnly
        let wax = sealed ? try WaxSeal.image(id: d.match?.id ?? d.interlaced ?? SealID(0), size: 380) : try WaxSeal.ghost(size: 380)
        var lines: [(String, RenderCanvas.RGB)] = []
        if let m = d.match, sealed || d.verdict == .contentMismatch {
            if let label = m.label { lines.append(("“\(label)”", RenderCanvas.Palette.text)) }
            lines.append(("Sealed \(date.string(from: m.createdAt)) · \(m.id.short)", RenderCanvas.Palette.dim))
            lines.append((String(format: "%.0f%% of the original", 100 * m.coverage), RenderCanvas.Palette.text))
            lines.append(("\(m.retraced) of \(m.possible) hops retraced", RenderCanvas.Palette.text))
            lines.append(("\(m.inliers) anchors agree" + String(format: " · %.2f×", m.scale), RenderCanvas.Palette.dim))
            if let r = m.residualAgreement { lines.append((String(format: "residual agrees %.0f%%", 100 * r), RenderCanvas.Palette.dim)) }
        } else {
            lines.append(("No stored seal holds this picture", RenderCanvas.Palette.dim))
            lines.append(("\(d.seals) seals searched · \(d.anchors) anchors", RenderCanvas.Palette.dim))
        }
        if let id = d.interlaced { lines.append(("interlace names \(id.short)", RenderCanvas.Palette.dim)) }
        panel(canvas, l, wax: wax, title: d.verdict.words, titleColour: sealed ? rose : RenderCanvas.Palette.dim, lines: lines)
        canvas.text(BitmapFont.fitted(d.summary.uppercased(), pixels: l.pictureW, scale: 2), x: margin, y: 44, scale: 2, RenderCanvas.Palette.dim)
        canvas.text("THE BURGUNDY SEAL", x: margin, y: 18, scale: 2, rose)
        return try canvas.png()
    }
}

extension BurgundySeal {
    /// The detection graphic: the found picture with the seal's paths walked across it, and the wax seal.
    public static func graphic(_ detection: SealDetection, picture: CGImage?) throws -> Data {
        try SealGraphic.detection(detection, picture: picture)
    }

    /// The seal's digest: the picture as sealed with its anchors and paths, and its wax seal.
    public static func digest(_ record: SealRecord, picture: CGImage?) throws -> Data {
        try SealDigest.render(record, picture: picture)
    }

    /// The detection graphic over the picture at `url`.
    public static func graphic(_ detection: SealDetection, pictureAt url: URL) throws -> Data {
        try graphic(detection, picture: try ImageDecoding.cgImage(contentsOf: url))
    }

    /// The seal's digest over the picture at `url`.
    public static func digest(_ record: SealRecord, pictureAt url: URL) throws -> Data {
        try digest(record, picture: try ImageDecoding.cgImage(contentsOf: url))
    }
}
