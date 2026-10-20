//
//  PatchSampler.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The noiseprint's training patches: from each image, a recompression level drawn at
//        random (the same five levels in both classes, so the net cannot read "compression" as
//        the label), an optional identical downscale in both classes, then random 128-pixel gray
//        patches at native scale, blank ones dropped. Patches are stored as bytes (every gray
//        value is k / 255, so nothing is lost) and cached in the work area, keyed by everything
//        that decides them.
//  PIN:  the v202 reference's _patches, draw for draw from a CPython Random stream: random() < 0.5 then
//        uniform(0.5, 1.0) for the downscale (each side max(128, int(side·s))); choice() of the
//        level; randrange() for each patch's corner; std > 0.02 or the patch is dropped (not
//        redrawn). 24 patches per camera image, 16 per negative, then the first n of each class
//        with n the smaller count. Two departures, both named in every report: each image draws
//        from its own stream (seed, image index), so images can be cut in parallel and in any
//        order; and the levels are ImageIO's, with HEIC 0.75 for the reference's WebP 75 (macOS ImageIO
//        has no WebP encoder). Each image is flattened to the 8-bit bitmap inference reads before
//        anything else (ImageCodec), and gray is NoiseprintLens's round(BT.601) of it.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens

/// A recompression level, in both classes alike.
public enum NoiseprintLevel: String, Codable, Sendable, CaseIterable {
    case native, jpeg90, jpeg75, jpeg60, heic75

    /// The reference's names for the same levels (webp75 is the one stood in for).
    public var recipeName: String {
        switch self {
        case .native: return "native"
        case .jpeg90: return "q90"
        case .jpeg75: return "q75"
        case .jpeg60: return "q60"
        case .heic75: return "webp75"
        }
    }

    public func apply(_ cg: CGImage) throws -> CGImage {
        switch self {
        case .native: return cg
        case .jpeg90: return try ImageCodec.recompressed(cg, as: .jpeg, quality: 0.90)
        case .jpeg75: return try ImageCodec.recompressed(cg, as: .jpeg, quality: 0.75)
        case .jpeg60: return try ImageCodec.recompressed(cg, as: .jpeg, quality: 0.60)
        case .heic75: return try ImageCodec.recompressed(cg, as: .heic, quality: 0.75)
        }
    }
}

public struct PatchSettings: Codable, Sendable, Equatable {
    public var patch = 128
    public var cameraPatches = 24
    public var negativePatches = 16
    public var minimumStd = 0.02
    public var scaleAugment = true
    public var levels = NoiseprintLevel.allCases
    public var seed: UInt64 = 1

    public init() {}
}

/// The training patches of both classes, bytes, row-major, `patch`² each.
public struct PatchSet: Sendable {
    public var patch: Int
    public var pixels: [UInt8]
    /// 1 camera, 0 not.
    public var labels: [UInt8]
    public var count: Int { labels.count }

    /// Patch `i` as floats in [0, 1].
    public func floats(_ i: Int, into out: inout [Float], at offset: Int) {
        let n = patch * patch, base = i * n
        for k in 0..<n { out[offset + k] = Float(pixels[base + k]) / 255 }
    }
}

public enum PatchSampler {
    /// The patches of one image, drawn as the reference drew them, with the level that was drawn.
    public static func patches(_ cg: CGImage, count: Int, settings: PatchSettings, rng: inout PythonRandom) throws -> (patches: [[UInt8]], level: NoiseprintLevel) {
        let p = settings.patch
        var image = cg
        if settings.scaleAugment && rng.random() < 0.5 {
            let s = 0.5 + (1.0 - 0.5) * rng.random()
            let w = max(p, Int(Double(cg.width) * s)), h = max(p, Int(Double(cg.height) * s))
            guard let r = ImageCodec.resized(cg, width: w, height: h) else { throw VeilGardeFailure.internalError("the downscale failed") }
            image = r
        }
        let level = settings.levels[rng.randbelow(settings.levels.count)]
        image = try level.apply(image)
        guard let (g, w, h) = NoiseprintLens.grayBytes(image), w >= p, h >= p else { return ([], level) }
        var out: [[UInt8]] = []
        for _ in 0..<count {
            let y = rng.randbelow(h - p + 1), x = rng.randbelow(w - p + 1)
            var patch = [UInt8](repeating: 0, count: p * p)
            var sum = 0.0, sq = 0.0
            for row in 0..<p {
                let base = (y + row) * w + x
                for col in 0..<p {
                    let v = g[base + col]
                    patch[row * p + col] = v
                    let f = Double(v) / 255
                    sum += f; sq += f * f
                }
            }
            let n = Double(p * p), mean = sum / n
            if (max(0, sq / n - mean * mean)).squareRoot() > settings.minimumStd { out.append(patch) }
        }
        return (out, level)
    }

    /// One image's stream: the settings' seed and the image's place in its list.
    static func stream(seed: UInt64, index: Int) -> PythonRandom { PythonRandom(seed: seed &* 1_000_003 &+ UInt64(index)) }

    /// Patches from every image in `urls`, `count` each, cut `parallel` at a time, in list order.
    public static func sample(_ urls: [URL], count: Int, settings: PatchSettings, streamOffset: Int, parallel: Int = 6,
                              note: (String) -> Void = { _ in }) -> (patches: [[UInt8]], levels: [NoiseprintLevel: Int], failed: [String]) {
        var results = [([[UInt8]], NoiseprintLevel?, String?)](repeating: ([], nil, nil), count: urls.count)
        let lock = NSLock()
        var start = 0
        while start < urls.count {
            let end = min(start + parallel * 8, urls.count)
            DispatchQueue.concurrentPerform(iterations: end - start) { k in
                let i = start + k
                var rng = stream(seed: settings.seed, index: streamOffset + i)
                let result: ([[UInt8]], NoiseprintLevel?, String?)
                do {
                    let decoded = try ImageDecoding.cgImage(contentsOf: urls[i])
                    guard let cg = ImageCodec.flattened(decoded) else { throw VeilGardeFailure.internalError("cannot flatten the image") }
                    let (p, level) = try patches(cg, count: count, settings: settings, rng: &rng)
                    result = (p, level, nil)
                } catch { result = ([], nil, "\(urls[i].lastPathComponent): \(error)") }
                lock.lock(); results[i] = result; lock.unlock()
            }
            start = end
            note("noiseprint: patches from \(end) of \(urls.count) images")
        }
        var levels: [NoiseprintLevel: Int] = [:]
        for case let (_, level?, _) in results { levels[level, default: 0] += 1 }
        return (results.flatMap(\.0), levels, results.compactMap(\.2))
    }
}
