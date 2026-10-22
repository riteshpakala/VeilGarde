//
//  Watermark.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Sign an image (its native-resolution tile codes, sectioned) and match an image against a
//        signature (its codes at every grid phase, slid over the signature's). Nothing is added
//        to the pixels: the mark is what the warp residual already reads off them.
//  PIN:  v1 is a design under measurement, not a claim: `veilgarde watermark accept` runs the
//        acceptance and its kill criterion (Docs/site/08-watermark.html). Signing reads the grid at phase
//        (0, 0); a self-match therefore lands at offset 0, phase 0, score 1. Resizing is out of
//        scope for v1: a resized image changes its tiles and is measured only to show where it
//        breaks.
//

import CoreGraphics
import Foundation
import VeilGardeLens

public enum Watermark {
    public static func sign(_ cg: CGImage) throws -> WatermarkSignature {
        defer { LensRuntime.releaseMemory() }
        return WatermarkSignature(grid: TileCodeGrid(try NativePlane(cg).fragility()))
    }

    /// The image's tile codes at each phase, for matching against one or more signatures.
    public static func phaseCodes(_ cg: CGImage, phases: [Int] = MatchOptions.default.phases) throws -> [(px: Int, py: Int, codes: TileCodeGrid)] {
        defer { LensRuntime.releaseMemory() }
        let plane = try NativePlane(cg)
        var out: [(Int, Int, TileCodeGrid)] = []
        for py in phases {
            for px in phases {
                out.append((px, py, TileCodeGrid(plane.fragility(originX: px, originY: py))))
            }
        }
        return out
    }

    public static func match(codes: [(px: Int, py: Int, codes: TileCodeGrid)], against signature: WatermarkSignature,
                             options: MatchOptions = .default) -> MatchResult {
        let stored = signature.tileCodes
        var best = MatchResult.none
        for (px, py, crop) in codes {
            guard let b = Matcher.best(crop: crop, stored: stored, margin: options.margin, minimumBits: options.minimumBits) else { continue }
            if b.score > best.score || (b.score == best.score && b.bits > best.bitsCompared) {
                // The phase grid starts px into the image: its tile 0 sits at signed tile dx, so
                // the image's own origin is dx·32 − px on the signed image.
                best = MatchResult(offsetX: b.dx, offsetY: b.dy, phaseX: px, phaseY: py, score: b.score, bitsCompared: b.bits,
                                   zScore: Matcher.zScore(score: b.score, bits: b.bits), matched: false)
            }
        }
        best.matched = best.score >= options.threshold && best.bitsCompared >= options.minimumBits
        return best
    }

    public static func match(_ cg: CGImage, against signature: WatermarkSignature, options: MatchOptions = .default) throws -> MatchResult {
        match(codes: try phaseCodes(cg, phases: options.phases), against: signature, options: options)
    }
}
