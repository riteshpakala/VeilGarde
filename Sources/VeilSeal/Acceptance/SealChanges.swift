//
//  SealChanges.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The copies the seal's acceptance detects: Class I (crops, resizes, JPEG, the three
//        together), Class II's filters and region layers, and a simulated photo of a photo, each
//        made from a picture's 8-bit RGB pixels with nothing but CoreGraphics and ImageIO.
//  PIN:  The changes and their strengths are decision-155's and must not move without a new
//        decision. Every random choice (a crop's offset, a layer's region and colour, a recapture's
//        corners and turn, noise) comes from SplitMix64 seeded by the picture and the change, so a
//        run is the same twice. A crop keeps the picture's aspect: each side × √area. Hue turns by
//        the luminance-preserving rotation matrix (SVG's hueRotate); blur and sharpen are separable
//        Gaussians with edges extended; noise is Box–Muller. The recapture's homography moves each
//        corner by up to 6% of the side and turns by up to 5° about the centre, sampled bilinearly
//        over mid grey, then blur σ1, a warm cast, a vignette, noise σ3 and JPEG q80.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens

/// A picture's 8-bit RGB pixels, interleaved, rows top down.
public struct SealPixels: Sendable {
    public var width: Int
    public var height: Int
    public var rgb: [UInt8]

    public init(width: Int, height: Int, rgb: [UInt8]) {
        self.width = width
        self.height = height
        self.rgb = rgb
    }

    /// The picture drawn over white at `width × height` (its own size when nil).
    public init(_ cg: CGImage, width w: Int? = nil, height h: Int? = nil) throws {
        let w = w ?? cg.width, h = h ?? cg.height
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw VeilGardeFailure.internalError("cannot draw the picture at \(w)×\(h)") }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[3 * i] = bytes[4 * i]
            rgb[3 * i + 1] = bytes[4 * i + 1]
            rgb[3 * i + 2] = bytes[4 * i + 2]
        }
        self.init(width: w, height: h, rgb: rgb)
    }

    public func cgImage() throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(rgb) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw VeilGardeFailure.internalError("cannot make a \(width)×\(height) picture") }
        return cg
    }

    /// Each value through `f`, clamped and rounded.
    func mapped(_ f: (Float, Int) -> Float) -> SealPixels {
        var out = self
        for i in 0..<rgb.count { out.rgb[i] = Self.byte(f(Float(rgb[i]), i % 3)) }
        return out
    }

    /// Each pixel through `f` (r, g, b in, r, g, b out, 0–255).
    func perPixel(_ f: (Int, Int, Float, Float, Float) -> (Float, Float, Float)) -> SealPixels {
        var out = self
        for y in 0..<height {
            for x in 0..<width {
                let i = 3 * (y * width + x)
                let (r, g, b) = f(x, y, Float(rgb[i]), Float(rgb[i + 1]), Float(rgb[i + 2]))
                out.rgb[i] = Self.byte(r)
                out.rgb[i + 1] = Self.byte(g)
                out.rgb[i + 2] = Self.byte(b)
            }
        }
        return out
    }

    static func byte(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
}

/// One change decision-155 measures.
public enum SealChange: String, CaseIterable, Codable, Sendable {
    case crop50, crop25, resize50, resize75, resize150, resize200, jpeg90, jpeg75, jpeg60, combined
    case brightness, contrast, gamma, saturation, hue, grayscale, warm, blur, sharpen, noise
    case layerNormal, layerMultiply, layerScreen, layerOverlay, gradient, vignette, sticker
    case recapture

    public enum Group: String, Codable, Sendable { case classI, combined, filters, recapture }

    public var group: Group {
        switch self {
        case .crop50, .crop25, .resize50, .resize75, .resize150, .resize200, .jpeg90, .jpeg75, .jpeg60: return .classI
        case .combined: return .combined
        case .recapture: return .recapture
        default: return .filters
        }
    }

    /// The copy of `p`, its randomness seeded by `seed`.
    public func apply(_ p: SealPixels, seed: UInt64) throws -> SealPixels {
        var rng = SplitMix64(seed: seed)
        switch self {
        case .crop50: return SealChanges.crop(p, area: 0.5, &rng)
        case .crop25: return SealChanges.crop(p, area: 0.25, &rng)
        case .resize50: return try SealChanges.resize(p, 0.5)
        case .resize75: return try SealChanges.resize(p, 0.75)
        case .resize150: return try SealChanges.resize(p, 1.5)
        case .resize200: return try SealChanges.resize(p, 2)
        case .jpeg90: return try SealChanges.jpeg(p, 0.9)
        case .jpeg75: return try SealChanges.jpeg(p, 0.75)
        case .jpeg60: return try SealChanges.jpeg(p, 0.6)
        case .combined: return try SealChanges.jpeg(try SealChanges.resize(SealChanges.crop(p, area: 0.5, &rng), 0.75), 0.75)
        case .brightness: return p.mapped { v, _ in v + 20 }
        case .contrast: return p.mapped { v, _ in (v - 128) * 1.3 + 128 }
        case .gamma: return p.mapped { v, _ in 255 * pow(v / 255, 0.8) }
        case .saturation: return SealChanges.saturate(p, 0.5)
        case .hue: return SealChanges.hue(p, degrees: 15)
        case .grayscale: return SealChanges.saturate(p, 0)
        case .warm: return p.mapped { v, c in c == 0 ? 255 * pow(v / 255, 0.85) : c == 2 ? 255 * pow(v / 255, 1.15) : v }
        case .blur: return SealChanges.blurred(p, sigma: 1.5)
        case .sharpen: return SealChanges.sharpened(p)
        case .noise: return SealChanges.noisy(p, sigma: 5, &rng)
        case .layerNormal: return SealChanges.layer(p, .normal, &rng)
        case .layerMultiply: return SealChanges.layer(p, .multiply, &rng)
        case .layerScreen: return SealChanges.layer(p, .screen, &rng)
        case .layerOverlay: return SealChanges.layer(p, .overlay, &rng)
        case .gradient: return SealChanges.gradient(p, &rng)
        case .vignette: return SealChanges.vignette(p, strength: 0.5)
        case .sticker: return SealChanges.sticker(p, &rng)
        case .recapture: return try SealChanges.recapture(p, &rng)
        }
    }
}

enum SealChanges {
    static func crop(_ p: SealPixels, area: Double, _ rng: inout SplitMix64) -> SealPixels {
        let side = area.squareRoot()
        let w = max(1, Int((Double(p.width) * side).rounded())), h = max(1, Int((Double(p.height) * side).rounded()))
        let x0 = Int(rng.unit() * Double(p.width - w + 1)), y0 = Int(rng.unit() * Double(p.height - h + 1))
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            let from = 3 * ((y0 + y) * p.width + x0)
            rgb.replaceSubrange((3 * y * w)..<(3 * (y + 1) * w), with: p.rgb[from..<(from + 3 * w)])
        }
        return SealPixels(width: w, height: h, rgb: rgb)
    }

    static func resize(_ p: SealPixels, _ factor: Double) throws -> SealPixels {
        let cg = try p.cgImage()
        guard let scaled = ImageCodec.resized(cg, by: factor) else { throw VeilGardeFailure.internalError("cannot resize by \(factor)") }
        return try SealPixels(scaled)
    }

    static func jpeg(_ p: SealPixels, _ quality: Double) throws -> SealPixels {
        try SealPixels(try ImageCodec.recompressed(try p.cgImage(), as: .jpeg, quality: quality))
    }

    static func saturate(_ p: SealPixels, _ s: Float) -> SealPixels {
        p.perPixel { _, _, r, g, b in
            let l = 0.299 * r + 0.587 * g + 0.114 * b
            return (l + s * (r - l), l + s * (g - l), l + s * (b - l))
        }
    }

    static func hue(_ p: SealPixels, degrees: Float) -> SealPixels {
        let a = degrees * .pi / 180, c = cos(a), s = sin(a)
        let m: [Float] = [
            0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928,
            0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283,
            0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072,
        ]
        return p.perPixel { _, _, r, g, b in
            (m[0] * r + m[1] * g + m[2] * b, m[3] * r + m[4] * g + m[5] * b, m[6] * r + m[7] * g + m[8] * b)
        }
    }

    /// Each channel blurred by a separable Gaussian, as floats.
    static func blurredPlanes(_ p: SealPixels, sigma: Float) -> [Float] {
        let radius = max(1, Int((3 * sigma).rounded(.up)))
        var kernel = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        let w = p.width, h = p.height
        var tmp = [Float](repeating: 0, count: p.rgb.count), out = tmp
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    var acc: Float = 0
                    for k in -radius...radius { acc += kernel[k + radius] * Float(p.rgb[3 * (y * w + min(w - 1, max(0, x + k))) + c]) }
                    tmp[3 * (y * w + x) + c] = acc
                }
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    var acc: Float = 0
                    for k in -radius...radius { acc += kernel[k + radius] * tmp[3 * (min(h - 1, max(0, y + k)) * w + x) + c] }
                    out[3 * (y * w + x) + c] = acc
                }
            }
        }
        return out
    }

    static func blurred(_ p: SealPixels, sigma: Float) -> SealPixels {
        let b = blurredPlanes(p, sigma: sigma)
        return p.indexed { b[$0] }
    }

    /// Unsharp mask: amount 1 over a σ 1 blur.
    static func sharpened(_ p: SealPixels) -> SealPixels {
        let b = blurredPlanes(p, sigma: 1)
        return p.indexed { 2 * Float(p.rgb[$0]) - b[$0] }
    }

    static func gaussian(_ rng: inout SplitMix64) -> Float {
        let u = max(1e-12, rng.unit()), v = rng.unit()
        return Float((-2 * log(u)).squareRoot() * cos(2 * .pi * v))
    }

    static func noisy(_ p: SealPixels, sigma: Float, _ rng: inout SplitMix64) -> SealPixels {
        var out = p
        for i in 0..<p.rgb.count { out.rgb[i] = SealPixels.byte(Float(p.rgb[i]) + sigma * gaussian(&rng)) }
        return out
    }

    enum Blend { case normal, multiply, screen, overlay }

    static let colours: [(Float, Float, Float)] = [(220, 40, 60), (30, 90, 200), (250, 200, 40), (40, 160, 90), (120, 40, 160), (250, 130, 30)]

    /// A solid colour at 30% over a seeded region of 30–50% of the area.
    static func layer(_ p: SealPixels, _ blend: Blend, _ rng: inout SplitMix64) -> SealPixels {
        let area = 0.3 + 0.2 * rng.unit(), aspect = 0.6 + 0.8 * rng.unit()
        let w = min(p.width, Int(Double(p.width) * (area * aspect).squareRoot())), h = min(p.height, Int(Double(p.height) * (area / aspect).squareRoot()))
        let x0 = Int(rng.unit() * Double(p.width - w + 1)), y0 = Int(rng.unit() * Double(p.height - h + 1))
        let colour = colours[rng.index(colours.count)]
        let alpha: Float = 0.3
        func mix(_ a: Float, _ c: Float) -> Float {
            let s = a / 255, t = c / 255
            let blended: Float
            switch blend {
            case .normal: blended = t
            case .multiply: blended = s * t
            case .screen: blended = 1 - (1 - s) * (1 - t)
            case .overlay: blended = s < 0.5 ? 2 * s * t : 1 - 2 * (1 - s) * (1 - t)
            }
            return 255 * (s + alpha * (blended - s))
        }
        return p.perPixel { x, y, r, g, b in
            guard x >= x0, x < x0 + w, y >= y0, y < y0 + h else { return (r, g, b) }
            return (mix(r, colour.0), mix(g, colour.1), mix(b, colour.2))
        }
    }

    /// A colour fading from 40% at one seeded edge to nothing at the other.
    static func gradient(_ p: SealPixels, _ rng: inout SplitMix64) -> SealPixels {
        let colour = colours[rng.index(colours.count)]
        let angle = Float(rng.unit() * 2 * .pi), dx = cos(angle), dy = sin(angle)
        let cx = Float(p.width) / 2, cy = Float(p.height) / 2, reach = (abs(dx) * cx + abs(dy) * cy)
        return p.perPixel { x, y, r, g, b in
            let t = ((Float(x) - cx) * dx + (Float(y) - cy) * dy) / max(1, reach)
            let a = 0.4 * max(0, min(1, (1 - t) / 2))
            return (r + a * (colour.0 - r), g + a * (colour.1 - g), b + a * (colour.2 - b))
        }
    }

    static func vignette(_ p: SealPixels, strength: Float) -> SealPixels {
        let cx = Float(p.width) / 2, cy = Float(p.height) / 2, far = (cx * cx + cy * cy).squareRoot()
        return p.perPixel { x, y, r, g, b in
            let d = ((Float(x) - cx) * (Float(x) - cx) + (Float(y) - cy) * (Float(y) - cy)).squareRoot() / far
            let k = 1 - strength * d * d
            return (r * k, g * k, b * k)
        }
    }

    /// An opaque block over 15% of the area: a solid ground with darker bars, like a sticker or a caption.
    static func sticker(_ p: SealPixels, _ rng: inout SplitMix64) -> SealPixels {
        let aspect = 1 + 2 * rng.unit()
        let w = min(p.width, Int(Double(p.width) * (0.15 * aspect).squareRoot())), h = min(p.height, Int(Double(p.height) * (0.15 / aspect).squareRoot()))
        let x0 = Int(rng.unit() * Double(p.width - w + 1)), y0 = Int(rng.unit() * Double(p.height - h + 1))
        let ground = colours[rng.index(colours.count)]
        let bar = max(4, h / 8)
        return p.perPixel { x, y, r, g, b in
            guard x >= x0, x < x0 + w, y >= y0, y < y0 + h else { return (r, g, b) }
            let row = (y - y0) / bar, inset = x - x0 > w / 10 && x0 + w - x > w / 10
            return row % 2 == 1 && inset ? (ground.0 * 0.3, ground.1 * 0.3, ground.2 * 0.3) : ground
        }
    }

    /// A screen or print photographed again: moved corners and a turn, then blur, a cast, a vignette, noise and JPEG.
    static func recapture(_ p: SealPixels, _ rng: inout SplitMix64) throws -> SealPixels {
        let w = Double(p.width), h = Double(p.height)
        let turn = (rng.unit() * 2 - 1) * 5 * .pi / 180
        let corners = [(0.0, 0.0), (w, 0), (w, h), (0, h)]
        let cx = w / 2, cy = h / 2
        let moved = corners.map { x, y -> (Double, Double) in
            let rx = cx + cos(turn) * (x - cx) - sin(turn) * (y - cy), ry = cy + sin(turn) * (x - cx) + cos(turn) * (y - cy)
            return (rx + (rng.unit() * 2 - 1) * 0.06 * w, ry + (rng.unit() * 2 - 1) * 0.06 * h)
        }
        // The homography from output pixels back to the source: moved corners → corners.
        var a = [Double](), b = [Double]()
        for ((u, v), (x, y)) in zip(moved, corners) {
            a += [u, v, 1, 0, 0, 0, -x * u, -x * v]
            b.append(x)
            a += [0, 0, 0, u, v, 1, -y * u, -y * v]
            b.append(y)
        }
        guard let hm = Consensus.solve(a, b, 8) else { throw VeilGardeFailure.internalError("recapture: no homography") }
        var out = SealPixels(width: p.width, height: p.height, rgb: [UInt8](repeating: 120, count: p.rgb.count))
        for v in 0..<p.height {
            for u in 0..<p.width {
                let du = Double(u) + 0.5, dv = Double(v) + 0.5
                let z = hm[6] * du + hm[7] * dv + 1
                let sx = (hm[0] * du + hm[1] * dv + hm[2]) / z - 0.5, sy = (hm[3] * du + hm[4] * dv + hm[5]) / z - 0.5
                guard sx >= 0, sy >= 0, sx <= w - 1, sy <= h - 1 else { continue }
                let x0 = Int(sx), y0 = Int(sy), x1 = min(p.width - 1, x0 + 1), y1 = min(p.height - 1, y0 + 1)
                let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
                for c in 0..<3 {
                    let q00 = Float(p.rgb[3 * (y0 * p.width + x0) + c]), q10 = Float(p.rgb[3 * (y0 * p.width + x1) + c])
                    let q01 = Float(p.rgb[3 * (y1 * p.width + x0) + c]), q11 = Float(p.rgb[3 * (y1 * p.width + x1) + c])
                    let top = q00 + fx * (q10 - q00), bottom = q01 + fx * (q11 - q01)
                    out.rgb[3 * (v * p.width + u) + c] = SealPixels.byte(top + fy * (bottom - top))
                }
            }
        }
        var shot = blurred(out, sigma: 1)
        shot = shot.mapped { v, c in c == 0 ? v * 1.05 + 6 : c == 2 ? v * 0.92 : v + 2 }
        shot = vignette(shot, strength: 0.3)
        shot = noisy(shot, sigma: 3, &rng)
        return try jpeg(shot, 0.8)
    }
}

extension SealPixels {
    /// Each value replaced by `f(index)`, clamped and rounded.
    func indexed(_ f: (Int) -> Float) -> SealPixels {
        var out = self
        for i in 0..<rgb.count { out.rgb[i] = Self.byte(f(i)) }
        return out
    }
}
