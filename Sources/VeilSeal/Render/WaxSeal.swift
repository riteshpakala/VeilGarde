//
//  WaxSeal.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The Burgundy Seal itself: a letter seal in the colours of the arms of Lyon — a thin rim of
//        teal wax (the shield's border) curling up and melting in over a burgundy stamp face (its
//        field), the RR mark pressed into the face with a brushed-platinum sheen (its lion) and three
//        gold flakes in a row above it (its chief's fleurs-de-lis) — drawn from a height field and lit
//        from the upper left. Each seal's wax runs its own way: the rim's lobes, drips and tongues, the
//        flakes' torn edges and the brushing are seeded from the seal's id. `ghost` is the outline a
//        picture that holds no seal is shown with.
//  PIN:  Height = a thin rim r(θ) = R(0.86 + Σ waves + 0.45 Σ drips) climbing from its outer edge
//        to a crest at its lip, 0.70R less the tongues melting inward (by the id, narrow ones that
//        pinch in or wide ones that round off), where it rolls 0.045R over onto a face sitting low;
//        ahead of the lip the red is pushed up into a swell and a fainter ripple and marbled with teal
//        veins drawn along the rim. Then two engraved rings (half smoothed over where the red was
//        pushed), the RR mark (0.94R wide, 0.07R below the centre) pressed 0.32 deeper with its
//        silhouette softened by two box blurs, and gold leaf raised 0.06 with a crinkle. R = 0.42 of
//        the picture. Shading: diffuse between each surface's three tones (Style.lyon, sampled from a
//        photograph of the arms on a Lyon facade); the mark's lit faces lean to platinum, streaked by
//        value noise drawn along a stroke 20° off the horizontal; Blinn-Phong highlights (wax 40,
//        mark 50, gold 24), a soft shadow down and right. Seeds: SplitMix64 of the id. Pure CPU, no
//        CoreText, the same pixels every time.
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

    /// Three tones a surface is shaded between (in shadow, lit, in full light) and the tint of its highlight.
    struct Tones {
        var shadow: Colour, lit: Colour, full: Colour, gleam: Colour
    }

    /// One gold flake pressed into the face: where (in R from the centre, y down), how big (in R), turned how far.
    struct Flake {
        var x: Float, y: Float, size: Float, turn: Float
    }

    /// The seal's colourway, after the arms of Lyon: the melted rim, the stamp face, the mark and the flakes.
    struct Style {
        var rim: Tones
        var face: Tones
        var mark: Tones
        /// A brushed metal whose light the mark's highlights catch, if any.
        var sheen: Tones?
        var gold: Tones
        var flakes: [Flake]
        /// The mark's width in R, and how far below the centre it sits.
        var markWidth: Float
        var markDrop: Float
    }

    static let burgundyFace = Tones(shadow: deep, lit: wine, full: burgundy, gleam: gleam)
    static let lyonTeal = Tones(shadow: .hex(0x0F2C33), lit: .hex(0x275B6C), full: .hex(0x4F8592), gleam: Colour(r: 0.86, g: 1, b: 0.98))
    static let platinum = Tones(shadow: .hex(0x3E4249), lit: .hex(0xA0A4AA), full: .hex(0xEEF0EE), gleam: Colour(r: 1, g: 1, b: 1))
    static let gold = Tones(shadow: .hex(0x5A4119), lit: .hex(0xA8822F), full: .hex(0xE6C25E), gleam: Colour(r: 1, g: 0.95, b: 0.78))

    @inline(__always) static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// The seal for `id`, `size` px square, with alpha.
    static func image(id: SealID, size: Int) throws -> CGImage {
        let style = Style.lyon
        let s = size, c = Float(s) / 2, R = Float(s) * 0.42
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
        func bump(_ theta: Float, _ at: Float, _ width: Float) -> Float {
            var delta = theta - at
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            return exp(-delta * delta / (2 * width * width))
        }
        func rim(_ theta: Float) -> Float {
            var r: Float = 0.86
            for w in waves { r += w.a * sin(w.k * theta + w.phase) }
            for d in drips { r += 0.45 * d.size * bump(theta, d.at, d.width) }
            return R * r
        }
        // The rim's inner edge, where its lip rolls onto the face: tongues of wax melt inward.
        // Each seal melts in one of two ways, by its id: narrow tongues that pinch in, or wide ones that round off.
        let (sizes, widths): ((Float, Float), (Float, Float)) = pinched(id) ? ((0.025, 0.05), (0.06, 0.12)) : ((0.022, 0.042), (0.17, 0.20))
        let tongues: [(at: Float, size: Float, width: Float)] = (0..<(5 + Int(rng.unit() * 3))).map { _ in
            (at: Float(rng.unit() * 2 * .pi), size: sizes.0 + sizes.1 * Float(rng.unit()), width: widths.0 + widths.1 * Float(rng.unit()))
        }
        func lip(_ theta: Float) -> Float {
            var r: Float = 0.70
            for t in tongues { r -= t.size * bump(theta, t.at, t.width) }
            return R * r
        }

        // The RR mark, softened, fitted to 1.04R wide at the centre.
        let markW = style.markWidth * R, markH = markW * Float(RRMarkMask.height) / Float(RRMarkMask.width)
        let soft = softenedMark()
        func mark(_ x: Float, _ y: Float) -> Float {
            let u = (x - (c - markW / 2)) / markW * Float(RRMarkMask.width), v = (y - (c - markH / 2 + style.markDrop * R)) / markH * Float(RRMarkMask.height)
            guard u >= 0, v >= 0, u < Float(RRMarkMask.width - 1), v < Float(RRMarkMask.height - 1) else { return 0 }
            let x0 = Int(u), y0 = Int(v), ax = u - Float(x0), ay = v - Float(y0), w = RRMarkMask.width
            let top = soft[y0 * w + x0] * (1 - ax) + soft[y0 * w + x0 + 1] * ax
            let bottom = soft[(y0 + 1) * w + x0] * (1 - ax) + soft[(y0 + 1) * w + x0 + 1] * ax
            return top * (1 - ay) + bottom * ay
        }

        // The flakes: torn leaf, each edge its id's own.
        var leaf = SplitMix64(seed: id.value ^ 0x601D_F1A4_E5EA_1002)
        let flakes = style.flakes.map { f -> (x: Float, y: Float, size: Float, turn: Float, tears: [(Float, Float, Float)]) in
            let tears: [(Float, Float, Float)] = [(3, 0.17), (5, 0.11), (7, 0.07), (17, 0.035)].map {
                ($0.0, $0.1 * Float(0.6 + 0.8 * leaf.unit()), Float(leaf.unit() * 2 * .pi))
            }
            let jitter = Float(leaf.unit() - 0.5) * 0.03
            return (x: c + (f.x + jitter) * R, y: c + (f.y + jitter) * R, size: f.size * R * Float(0.9 + 0.2 * leaf.unit()),
                    turn: f.turn + Float(leaf.unit() - 0.5), tears: tears)
        }
        func flake(_ x: Float, _ y: Float) -> Float {
            var best: Float = 0
            for f in flakes {
                let dx = x - f.x, dy = y - f.y
                guard abs(dx) < 2 * f.size, abs(dy) < 2 * f.size else { continue }
                let u = (dx * cos(f.turn) + dy * sin(f.turn)) / 1.25, v = -dx * sin(f.turn) + dy * cos(f.turn)
                let phi = atan2(v, u)
                var edge: Float = 1
                for t in f.tears { edge += t.1 * sin(t.0 * phi + t.2) }
                best = max(best, min(1, max(0, f.size * edge - (u * u + v * v).squareRoot() + 0.5)))
            }
            return best
        }

        // Brushed metal: value noise stretched along a stroke 20° off the horizontal, two octaves.
        func hash(_ i: Int, _ j: Int, _ salt: UInt64) -> Float {
            var z = UInt64(bitPattern: Int64(i)) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: Int64(j)) &* 0xC2B2_AE3D_27D4_EB4F ^ salt
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24)
        }
        func noise(_ u: Float, _ v: Float, _ salt: UInt64) -> Float {
            let i = Int(u.rounded(.down)), j = Int(v.rounded(.down)), a = u - Float(i), b = v - Float(j)
            let top = hash(i, j, salt) * (1 - a) + hash(i + 1, j, salt) * a, bottom = hash(i, j + 1, salt) * (1 - a) + hash(i + 1, j + 1, salt) * a
            return top * (1 - b) + bottom * b
        }
        let along = (cos(Float(-0.35)), sin(Float(-0.35)))
        let fine = max(0.6, Float(s) / 700)
        func brushed(_ x: Float, _ y: Float) -> Float {
            let u = x * along.0 + y * along.1, v = -x * along.1 + y * along.0
            return 0.65 * noise(u / (30 * fine), v / fine, id.value) + 0.35 * noise(u / (70 * fine), v / (3 * fine), ~id.value)
        }

        var height = [Float](repeating: 0, count: s * s)
        var coverage = [Float](repeating: 0, count: s * s)
        var metal = [Float](repeating: 0, count: s * s)
        var leafGold = [Float](repeating: 0, count: s * s)
        var rimWax = [Float](repeating: 0, count: s * s)
        var hollow = [Float](repeating: 0, count: s * s)
        var veins = [Float](repeating: 0, count: s * s)
        let face = 0.70 * R
        var grainSeed = SplitMix64(seed: id.value)
        let grain = (0..<(64 * 64)).map { _ in Float(grainSeed.unit()) }
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
                let theta = atan2(dy, dx)
                let edge = rim(theta)
                let inside = edge - rho
                let i = y * s + x
                coverage[i] = min(1, max(0, inside + 0.5))
                guard inside > -1 else { continue }
                // The face sits low; the rim climbs from its outer edge to a crest at the lip and rolls over onto the face.
                var h: Float
                var impact: Float = 0
                let inner = lip(theta), roll = 0.045 * R
                let faceH: Float = 0.45 + 0.08 * (1 - min(1, (rho / face) * (rho / face)))
                let climb = min(1, max(0, (edge - rho) / max(1, edge - inner)))
                let wax = smoothstep(0, 0.07 * R, inside) * (0.6 + 0.75 * climb * climb)
                if rho >= inner {
                    rimWax[i] = 1
                    h = wax
                } else {
                    let t = (inner - rho) / roll
                    let lipH = t < 1 ? faceH + (wax - faceH) * (1 - t * t).squareRoot() : faceH - 1
                    rimWax[i] = smoothstep(-0.01, 0.04, lipH - faceH)
                    // Where the teal ran in, the red is pushed up into a swell and a fainter ripple, and marbled with teal.
                    let d = max(0, inner - roll - rho)
                    let swell = (d - 0.035 * R) / (0.032 * R), ripple = (d - 0.11 * R) / (0.025 * R)
                    impact = exp(-swell * swell) + 0.35 * exp(-ripple * ripple)
                    let red = 1 - rimWax[i]
                    // Streaks run along the rim; two samples a turn apart, crossfaded, close the seam at θ = ±π.
                    func marbleAt(_ t: Float) -> Float {
                        let along = t * R / fine, across = rho / fine
                        return 0.7 * noise(along / 26, across / 3.2, id.value ^ 0x7EA1) + 0.3 * noise(along / 9, across / 1.4, id.value ^ 0x7EA2)
                    }
                    let w = (theta + .pi) / (2 * .pi)
                    let marble = w * marbleAt(theta) + (1 - w) * marbleAt(theta + 2 * .pi)
                    veins[i] = red * exp(-d / (0.11 * R)) * (0.22 + 0.78 * smoothstep(0.5, 0.66, marble))
                    hollow[i] = red * 0.22 * exp(-d / (0.03 * R))
                    h = max(faceH + 0.2 * red * impact, lipH)
                }
                let under = 1 - rimWax[i]
                let ring1 = (rho - 0.62 * R) / (0.009 * R), ring2 = (rho - 0.585 * R) / (0.006 * R)
                h += under * (1 - 0.6 * min(1, impact)) * (0.10 * exp(-ring1 * ring1) + 0.07 * exp(-ring2 * ring2))
                let m = under * mark(Float(x) + 0.5, Float(y) + 0.5)
                h -= 0.32 * m
                metal[i] = smoothstep(0.3, 0.7, m)
                let g = under * flake(Float(x) + 0.5, Float(y) + 0.5)
                leafGold[i] = g
                // Wax grain, smoothed under the polished mark; gold leaf crinkles.
                h += (1 - 0.7 * metal[i]) * (0.025 * grainAt(Float(x), Float(y), 7) + 0.012 * grainAt(Float(x) + 31, Float(y) + 17, 2.5))
                h += g * (0.06 + 0.022 * grainAt(Float(x) + 11, Float(y) + 5, 3.5) + 0.012 * grainAt(Float(x) + 3, Float(y) + 29, 1.8))
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
                    let facing = max(0, n.0 * half.0 + n.1 * half.1 + n.2 * half.2)
                    func shade(_ t: Tones, _ d: Float) -> Colour {
                        t.shadow.mix(t.lit, smoothstep(0.15, 0.62, d)).mix(t.full, smoothstep(0.62, 0.97, d))
                    }
                    // Wax: the rim's tones outside the stamp face, the face's within.
                    let dx = Float(x) + 0.5 - c, dy = Float(y) + 0.5 - c
                    let inFace = 1 - rimWax[i]
                    let waxGleam = style.rim.gleam.mix(style.face.gleam, inFace)
                    let spec = pow(facing, 40) * 0.55
                    let depth = (0.8 + 0.2 * min(1, max(0, height[i]))) * (1 - hollow[i])
                    let wax = shade(style.rim, diffuse).mix(shade(style.face, diffuse), inFace).mix(shade(style.rim, diffuse), 0.9 * veins[i])
                    colour = Colour(r: wax.r * depth + waxGleam.r * spec, g: wax.g * depth + waxGleam.g * spec, b: wax.b * depth + waxGleam.b * spec)
                    // Platinum: a broad reflection falling from the upper left, sharp highlights on the bevels.
                    if metal[i] > 0 {
                        let sky = 0.5 + 0.5 * max(-1, min(1, (-dx * 0.62 - dy * 0.78) / (0.9 * R)))
                        let brush = brushed(Float(x), Float(y))
                        let light = 0.6 * diffuse + 0.4 * sky
                        var p = shade(style.mark, light)
                        var tint = style.mark.gleam
                        if let sheen = style.sheen {
                            p = p.mix(shade(sheen, diffuse), 0.6 * smoothstep(0.42, 0.85, light) * (0.55 + 0.45 * brush))
                            tint = sheen.gleam
                        }
                        let grain = 0.86 + 0.28 * brush
                        let ps = pow(facing, 50) * 0.75 * (0.4 + brush)
                        colour = colour.mix(Colour(r: p.r * grain + tint.r * ps, g: p.g * grain + tint.g * ps, b: p.b * grain + tint.b * ps), metal[i])
                    }
                    // Gold leaf: deep where it faces away, bright and warm where it catches the light.
                    if leafGold[i] > 0 {
                        let gl = shade(style.gold, diffuse)
                        let gs = pow(facing, 24) * 1.1
                        colour = colour.mix(Colour(r: gl.r + style.gold.gleam.r * gs, g: gl.g + style.gold.gleam.g * gs, b: gl.b + style.gold.gleam.b * gs), leafGold[i])
                    }
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

    /// Whether `id`'s rim melts in with narrow, pinching tongues (else wide, rounded ones): half of all seals, by a hash of the id.
    static func pinched(_ id: SealID) -> Bool {
        var pick = SplitMix64(seed: id.value ^ 0x7096_E5ED_CE11_0003)
        return pick.unit() < 0.5
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

extension WaxSeal.Style {
    /// Teal melted rim, burgundy face, the mark pressed in with a brushed-platinum sheen, three gold flakes in a row above it (Lyon's chief).
    static let lyon = WaxSeal.Style(rim: WaxSeal.lyonTeal, face: WaxSeal.burgundyFace, mark: WaxSeal.burgundyFace, sheen: WaxSeal.platinum, gold: WaxSeal.gold,
                                    flakes: [.init(x: -0.19, y: -0.46, size: 0.062, turn: 0.3), .init(x: 0, y: -0.49, size: 0.07, turn: -0.5),
                                             .init(x: 0.19, y: -0.46, size: 0.062, turn: 1.1)],
                                    markWidth: 0.94, markDrop: 0.07)
}
