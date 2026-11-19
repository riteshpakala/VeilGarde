//
//  SealAnchorTests.swift
//  VeilSealTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The seal's steps on the CPU: anchors are found the same way twice and reappear after a crop, a
//        resize and a re-encode; a pattern stays near its partner's and far from a stranger's; the keyed
//        comparisons are pinned; paths read the same after a similarity; consensus recovers a transform
//        through outliers; a code's hex round-trips.
//  PIN:  Repeatability counts an anchor found again within max(3 px, σ/2) of where the known transform
//        puts it, at a scale within 1.5×, among the anchors whose place the copy holds.
//

import CoreGraphics
import Foundation
import Testing
import VeilGardeCore
import VeilGardeLens
@testable import VeilSeal

@Suite("The seal's anchors, patterns and paths")
struct SealAnchorTests {
    static let measure = HSLPattern(key: .default)

    static func read(_ cg: CGImage, count: Int = AnchorReading.sealCount) throws -> AnchorReading {
        try AnchorReading.read(cg, key: .default, measure: measure, count: count, residual: false)
    }

    static func picture(_ name: String) throws -> CGImage { try ImageDecoding.cgImage(contentsOf: Fixture.crop(name)) }

    /// The share of `a`'s anchors (those `map` puts inside `b`'s picture) that `b` holds again, and their partners.
    static func repeatability(_ a: AnchorReading, _ b: AnchorReading, scale: Float, map: (Float, Float) -> (Float, Float)) -> (Double, [(Anchor, Anchor)]) {
        var held = 0, inside = 0
        var partners: [(Anchor, Anchor)] = []
        for x in a.anchors {
            let (px, py) = map(x.x, x.y)
            guard px >= 0, py >= 0, px < Float(b.width), py < Float(b.height) else { continue }
            inside += 1
            let reach = max(3, x.scale * scale / 2)
            if let y = b.anchors.first(where: {
                hypot($0.x - px, $0.y - py) <= reach && $0.scale / (x.scale * scale) < 1.5 && $0.scale / (x.scale * scale) > 1 / 1.5
            }) {
                held += 1
                partners.append((x, y))
            }
        }
        return (inside > 0 ? Double(held) / Double(inside) : 0, partners)
    }

    @Test("a picture's anchors are found the same way twice, spread over it, with positions in its own pixels")
    func deterministic() throws {
        let cg = try Self.picture("crop_ben.png")
        let a = try Self.read(cg), b = try Self.read(cg)
        #expect(a.anchors == b.anchors)
        #expect(a.anchors.count >= 150, "\(a.anchors.count) anchors")
        #expect(a.anchors.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x < 512 && $0.y < 512 && $0.scale > 1 })
        #expect(a.anchors.allSatisfy { $0.fragility == nil && $0.residual == nil }, "no residual without MLX")
    }

    @Test("anchors reappear after a crop, a 0.5× and a 2× resize and JPEG 75, and their patterns stay near", arguments: ["crop", "half", "double", "jpeg75"])
    func repeatable(change: String) throws {
        let cg = try Self.picture("crop_fox.png")
        let a = try Self.read(cg)
        let copy: CGImage
        var scale: Float = 1
        var map: (Float, Float) -> (Float, Float) = { ($0, $1) }
        switch change {
        case "crop":
            copy = try MarkFixture.crop(cg, x: 100, y: 80, w: 300, h: 300)
            map = { ($0 - 100, $1 - 80) }
        case "half":
            copy = try #require(ImageCodec.resized(cg, by: 0.5))
            scale = 0.5
        case "double":
            copy = try #require(ImageCodec.resized(cg, by: 2))
            scale = 2
        default:
            copy = try ImageCodec.recompressed(cg, as: .jpeg, quality: 0.75)
        }
        let s = scale
        let b = try Self.read(copy, count: AnchorReading.searchCount)
        let (rate, partners) = Self.repeatability(a, b, scale: s) { x, y in
            let (mx, my) = map(x, y)
            return (mx * s, my * s)
        }
        let floor: Double = change == "half" ? 0.25 : 0.6
        #expect(rate >= floor, "\(change): \(Int(rate * 100))% of anchors found again")
        let near = partners.map { $0.0.code.distance($0.1.code) }
        let mean = Double(near.reduce(0, +)) / Double(max(1, near.count))
        let strangers = zip(a.anchors.prefix(200), a.anchors.dropFirst(200).prefix(200)).map { $0.code.distance($1.code) }
        let strangerMean = Double(strangers.reduce(0, +)) / Double(max(1, strangers.count))
        // Unrelated patterns sit about 86 bits apart, not 128: oriented squares make the comparisons correlated
        // (2026-11-18). A7 chooses the pairs by flip rate and decorrelation.
        #expect(mean < 32 && strangerMean > 72, "\(change): partners \(mean) bits apart, strangers \(strangerMean)")
    }

    @Test("the default key's comparisons and pointer bits are pinned")
    func pinnedPairs() {
        var bytes: [UInt8] = []
        for (p, q) in Self.measure.pairs { bytes += [UInt8(p >> 8), UInt8(p & 255), UInt8(q >> 8), UInt8(q & 255)] }
        bytes += Self.measure.pointerBits.map { UInt8($0) }
        bytes += AnchorResidual.cellPairs(.default).flatMap { [UInt8($0.0), UInt8($0.1)] }
        #expect(ContentHash.sha256Hex(Data(bytes)) == "1bd6cdce4398285315117f5f010529ce582a2b292b0db8501d72e8f4374a13e2")
        #expect(HSLPattern(key: SealKey(phrase: "another")).pairs.map(\.0) != Self.measure.pairs.map(\.0), "another key, other comparisons")
    }

    @Test("a path reads the same after the anchors are moved, scaled and turned together")
    func pathsAreSimilarityInvariant() {
        let record = MarkFixture.record(count: 120)
        let s: Float = 1.7, t: Float = 0.6
        let moved = record.anchors.map { a -> Anchor in
            var b = a
            b.x = s * (cos(t) * a.x - sin(t) * a.y) + 40
            b.y = s * (sin(t) * a.x + cos(t) * a.y) - 25
            b.scale = a.scale * s
            b.angle = a.angle + t
            return b
        }
        let a = PathWalker.walk(record.anchors, pointerBits: Self.measure.pointerBits)
        let b = PathWalker.walk(moved, pointerBits: Self.measure.pointerBits)
        #expect(a.map(\.anchors) == b.map(\.anchors))
        #expect(!a.isEmpty && a.allSatisfy { $0.hops.count == $0.anchors.count - 1 })
        for (x, y) in zip(a.flatMap(\.hops), b.flatMap(\.hops)) {
            #expect(abs(x.reach - y.reach) < 1e-3 && abs(x.scale - y.scale) < 1e-3)
        }
    }

    @Test("consensus recovers a similarity and a homography through 60% outliers; retracing walks every shared hop")
    func consensus() throws {
        let record = MarkFixture.record(count: 150)
        let seal = record.anchors
        for projective in [false, true] {
            let truth = projective
                ? SealTransform(h: [0.8, 0.05, 30, -0.04, 0.85, 12, 0.0002, -0.0001, 1])
                : SealTransform.similarity(scale: 0.6, angle: 0.3, tx: 50, ty: -20)
            var query: [Anchor] = []
            var pairs: [Correspondence] = []
            var rng = SplitMix64(seed: 3)
            for (i, a) in seal.enumerated() {
                let (x, y) = truth.apply(Double(a.x), Double(a.y))
                var b = a
                b.x = Float(x + rng.unit() - 0.5)
                b.y = Float(y + rng.unit() - 0.5)
                b.scale = a.scale * Float(truth.scale(at: Double(a.x), Double(a.y)))
                let (ex, ey) = truth.apply(Double(a.x) + 1, Double(a.y))
                b.angle = a.angle + Float(atan2(ey - y, ex - x))
                if i % 5 < 3 {
                    b.x = Float(rng.unit() * 400)
                    b.y = Float(rng.unit() * 400)
                }
                query.append(b)
                pairs.append(Correspondence(seal: i, query: i, distance: 10))
            }
            let fit = try #require(Consensus.fit(pairs, seal: seal, query: query, tolerance: 4))
            #expect(fit.inliers.count >= 55 && fit.projective == projective, "projective \(projective): \(fit.inliers.count) inliers")
            for c in fit.inliers {
                let (x, y) = fit.transform.apply(Double(seal[c.seal].x), Double(seal[c.seal].y))
                let (u, v) = truth.apply(Double(seal[c.seal].x), Double(seal[c.seal].y))
                #expect(hypot(x - u, y - v) < 1.5)
            }
        }
        // The seal against itself: every hop's two anchors are shared, and every hop retraces.
        let all = seal.indices.map { Correspondence(seal: $0, query: $0, distance: 0) }
        let trace = PathRetracer.retrace(record.paths, seal: seal, query: seal, inliers: all, pointerBits: Self.measure.pointerBits)
        #expect(trace.possible == record.hopCount && trace.retraced == trace.possible)
    }

    @Test("a code's hex round-trips, bits read where they were set, distance counts differing bits")
    func codes() throws {
        var c = Code256()
        for n in [0, 63, 64, 130, 255] { c.set(n) }
        #expect([0, 63, 64, 130, 255].allSatisfy { c.bit($0) } && !c.bit(1))
        #expect(Code256(hex: c.hex) == c && c.distance(Code256()) == 5)
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(Code256.self, from: data) == c)
    }
}
