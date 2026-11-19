//
//  WaxSeal.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The Burgundy Seal itself: a letter seal of melted burgundy wax with the RR mark pressed into
//        it, drawn from a height field and lit from the upper left. Each seal's wax runs its own way:
//        the rim's lobes and drips are seeded from the seal's id. `ghost` is the outline a picture
//        that holds no seal is shown with.
//  PIN:  Height = a dome rising 0.18R in from a rim r(θ) = R(1 + Σ waves + Σ drips), a stamp face
//        pressed 0.55 inside 0.70R with the wax pushed up into a ridge at its edge, two engraved rings
//        and the RR mark raised 0.32 (its silhouette softened by two box blurs). Shading: diffuse
//        between #3E0710, #6E1222 and #9B2338, Blinn-Phong highlights (exponent 40), a soft shadow down
//        and right. Seeds: SplitMix64 of the id. Pure CPU, no CoreText, the same pixels every time.
//

import CoreGraphics
import Foundation
import VeilGardeCore

enum WaxSeal {
    struct Colour {
        var r: Float, g: Float, b: Float
        static func hex(_ v: UInt32) -> Colour {
            Colour(r: Float((v >> 16) & 255) / 255, g: Float((v >> 8) & 255) / 255, b: Float(v & 255) / 255)
        }
        func mix(_ o: Colour, _ t: Float) -> Colour { Colour(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
    }

    static let deep = Colour.hex(0x3E0710)
    static let wine = Colour.hex(0x6E1222)
    static let burgundy = Colour.hex(0x9B2338)
    static let gleam = Colour(r: 1, g: 0.84, b: 0.86)

    @inline(__always) static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// The seal for `id`, `size` px square, with alpha.
    static func image(id: SealID, size: Int) throws -> CGImage {
        let s = size, c = Float(s) / 2, R = Float(s) * 0.38
        var rng = SplitMix64(seed: id.value ^ 0xB0E6_A4D1_5EA1_0001)
        let base: [(Float, Float)] = [(3, 0.022), (5, 0.016), (7, 0.010), (11, 0.006)]
        let waves: [(k: Float, a: Float, phase: Float)] = base.map {
            (k: $0.0, a: $0.1 * Float(0.6 + 0.8 * rng.unit()), phase: Float(rng.unit() * 2 * .pi))
        }
        let dripCount = 5 + Int(rng.unit() * 3)
        var drips: [(at: Float, size: Float, width: Float)] = []
        for _ in 0..<dripCount {
            drips.append((at: Float(rng.unit() * 2 * .pi), size: Float(0.05 + 0.10 * rng.unit()), width: Float(0.10 + 0.20 * rng.unit())))
        }
        func rim(_ theta: Float) -> Float {
            var r: Float = 1
            for w in waves { r += w.a * sin(w.k * theta + w.phase) }
            for d in drips {
                var delta = theta - d.at
                while delta > .pi { delta -= 2 * .pi }
                while delta < -.pi { delta += 2 * .pi }
                r += d.size * exp(-delta * delta / (2 * d.width * d.width))
            }
            return R * r
        }

        // The RR mark, softened, fitted to 1.04R wide at the centre.
        let markW = 1.04 * R, markH = markW * Float(RRMarkMask.height) / Float(RRMarkMask.width)
        let soft = softenedMark()
        func mark(_ x: Float, _ y: Float) -> Float {
            let u = (x - (c - markW / 2)) / markW * Float(RRMarkMask.width), v = (y - (c - markH / 2 + 0.02 * R)) / markH * Float(RRMarkMask.height)
            guard u >= 0, v >= 0, u < Float(RRMarkMask.width - 1), v < Float(RRMarkMask.height - 1) else { return 0 }
            let x0 = Int(u), y0 = Int(v), ax = u - Float(x0), ay = v - Float(y0), w = RRMarkMask.width
            let top = soft[y0 * w + x0] * (1 - ax) + soft[y0 * w + x0 + 1] * ax
            let bottom = soft[(y0 + 1) * w + x0] * (1 - ax) + soft[(y0 + 1) * w + x0 + 1] * ax
            return top * (1 - ay) + bottom * ay
        }

        var height = [Float](repeating: 0, count: s * s)
        var coverage = [Float](repeating: 0, count: s * s)
        let face = 0.70 * R
        var noise = SplitMix64(seed: id.value)
        let grain = (0..<(64 * 64)).map { _ in Float(noise.unit()) }
        func grainAt(_ x: Float, _ y: Float, _ spacing: Float) -> Float {
            let u = x / spacing, v = y / spacing
            let x0 = Int(u.rounded(.down)), y0 = Int(v.rounded(.down)), ax = u - Float(x0), ay = v - Float(y0)
            func g(_ i: Int, _ j: Int) -> Float { grain[((j & 63) << 6) | (i & 63)] }
            let top = g(x0, y0) * (1 - ax) + g(x0 + 1, y0) * ax, bottom = g(x0, y0 + 1) * (1 - ax) + g(x0 + 1, y0 + 1) * ax
            return top * (1 - ay) + bottom * ay
        }
        for y in 0..<s {
            for x in 0..<s {
                let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c
                let rho = (dx * dx + dy * dy).squareRoot()
                let edge = rim(atan2(dy, dx))
                let inside = edge - rho
                let i = y * s + x
                coverage[i] = min(1, max(0, inside + 0.5))
                guard inside > -1 else { continue }
                var h = smoothstep(0, 0.18 * R, inside) + 0.15 * (1 - min(1, (rho / edge) * (rho / edge)))
                h -= 0.55 * smoothstep(face + 0.025 * R, face - 0.025 * R, rho)
                let ridge = (rho - face * 1.05) / (0.04 * R)
                h += 0.22 * exp(-ridge * ridge)
                let ring1 = (rho - 0.62 * R) / (0.009 * R), ring2 = (rho - 0.585 * R) / (0.006 * R)
                h += 0.10 * exp(-ring1 * ring1) + 0.07 * exp(-ring2 * ring2)
                h += 0.32 * mark(Float(x) + 0.5, Float(y) + 0.5)
                h += 0.025 * grainAt(Float(x), Float(y), 7) + 0.012 * grainAt(Float(x) + 31, Float(y) + 17, 2.5)
                height[i] = h
            }
        }

        // The shadow: the wax's coverage blurred and moved down and right.
        var shadow = coverage
        for _ in 0..<3 { shadow = boxBlur(shadow, s, s, radius: max(1, s / 60)) }
        let shift = max(1, s / 40)

        let light = normalised(-0.5, -0.62, 0.6)
        let half = normalised(light.0, light.1, light.2 + 1)
        let slope = Float(s) / 36
        var bytes = [UInt8](repeating: 0, count: s * s * 4)
        for y in 0..<s {
            for x in 0..<s {
                let i = y * s + x
                let sx = x - shift, sy = y - shift
                let shade = (sx >= 0 && sy >= 0) ? shadow[sy * s + sx] * 0.5 : 0
                let a = coverage[i]
                var colour = Colour(r: 0, g: 0, b: 0)
                if a > 0 {
                    let hx = (height[y * s + min(s - 1, x + 1)] - height[y * s + max(0, x - 1)]) / 2
                    let hy = (height[min(s - 1, y + 1) * s + x] - height[max(0, y - 1) * s + x]) / 2
                    let n = normalised(-hx * slope, -hy * slope, 1)
                    let diffuse = max(0, n.0 * light.0 + n.1 * light.1 + n.2 * light.2)
                    let spec = pow(max(0, n.0 * half.0 + n.1 * half.1 + n.2 * half.2), 40) * 0.55
                    colour = deep.mix(wine, smoothstep(0.15, 0.62, diffuse)).mix(burgundy, smoothstep(0.62, 0.97, diffuse))
                    let depth = 0.8 + 0.2 * min(1, max(0, height[i]))
                    colour = Colour(r: colour.r * depth + gleam.r * spec, g: colour.g * depth + gleam.g * spec, b: colour.b * depth + gleam.b * spec)
                }
                // Wax over shadow, premultiplied.
                let alpha = a + shade * (1 - a)
                bytes[4 * i] = UInt8(min(255, max(0, (colour.r * a) * 255)))
                bytes[4 * i + 1] = UInt8(min(255, max(0, (colour.g * a) * 255)))
                bytes[4 * i + 2] = UInt8(min(255, max(0, (colour.b * a) * 255)))
                bytes[4 * i + 3] = UInt8(min(255, max(0, alpha * 255)))
            }
        }
        return try rgbaImage(bytes, s, s)
    }

    /// A picture with no seal: a faint dashed outline where the seal would sit and the mark barely there.
    static func ghost(size: Int) throws -> CGImage {
        let s = size, c = Float(s) / 2, R = Float(s) * 0.38
        var bytes = [UInt8](repeating: 0, count: s * s * 4)
        let markW = 1.04 * R, markH = markW * Float(RRMarkMask.height) / Float(RRMarkMask.width)
        let soft = softenedMark()
        for y in 0..<s {
            for x in 0..<s {
                let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c
                let rho = (dx * dx + dy * dy).squareRoot()
                var a: Float = 0
                let ring = abs(rho - R)
                if ring < 1.5 {
                    let theta = atan2(dy, dx) + .pi
                    if Int(theta / (2 * .pi) * 48) % 2 == 0 { a = 0.55 * min(1, 1.5 - ring) }
                }
                let u = (Float(x) - (c - markW / 2)) / markW * Float(RRMarkMask.width), v = (Float(y) - (c - markH / 2)) / markH * Float(RRMarkMask.height)
                if u >= 0, v >= 0, u < Float(RRMarkMask.width), v < Float(RRMarkMask.height) {
                    a = max(a, 0.14 * soft[Int(v) * RRMarkMask.width + Int(u)])
                }
                let i = y * s + x
                let level: Float = 0.55
                bytes[4 * i] = UInt8(level * a * 255)
                bytes[4 * i + 1] = UInt8(level * 0.56 * a * 255)
                bytes[4 * i + 2] = UInt8(level * 0.6 * a * 255)
                bytes[4 * i + 3] = UInt8(a * 255)
            }
        }
        return try rgbaImage(bytes, s, s)
    }

    static func softenedMark() -> [Float] {
        let w = RRMarkMask.width, h = RRMarkMask.height
        var m = RRMarkMask.bits.map { $0 ? Float(1) : 0 }
        for _ in 0..<2 { m = boxBlur(m, w, h, radius: 2) }
        return m
    }

    static func boxBlur(_ v: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: v.count), out = tmp
        let n = Float(2 * r + 1)
        for y in 0..<h {
            var sum: Float = 0
            for k in -r...r { sum += v[y * w + min(w - 1, max(0, k))] }
            for x in 0..<w {
                tmp[y * w + x] = sum / n
                sum += v[y * w + min(w - 1, x + r + 1)] - v[y * w + max(0, x - r)]
            }
        }
        for x in 0..<w {
            var sum: Float = 0
            for k in -r...r { sum += tmp[min(h - 1, max(0, k)) * w + x] }
            for y in 0..<h {
                out[y * w + x] = sum / n
                sum += tmp[min(h - 1, y + r + 1) * w + x] - tmp[max(0, y - r) * w + x]
            }
        }
        return out
    }

    @inline(__always) static func normalised(_ x: Float, _ y: Float, _ z: Float) -> (Float, Float, Float) {
        let l = max(1e-6, (x * x + y * y + z * z).squareRoot())
        return (x / l, y / l, z / l)
    }

    static func rgbaImage(_ bytes: [UInt8], _ w: Int, _ h: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw VeilGardeFailure.internalError("cannot make a \(w)×\(h) seal image")
        }
        return image
    }
}
