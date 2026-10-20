//
//  PatchMap.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The terminal report of one detection: the P(generated) map in green, yellow and red, the
//        base verdict's weight map in blue, the weighted and majority verdicts with their trust,
//        the native check, the capture signature and the run times.
//  PIN:  Garde's printPretty layout, so a reader who knows `garde photo.jpg` reads this the same way.
//        Colour only on a terminal, never under --no-color or a JSON-to-stdout run.
//

import Foundation
import VeilGarde

enum PatchMap {
    /// Distance from the threshold, not from 0.5 (the reference `_confidence_label`).
    static func confidence(_ score: Float, threshold: Float) -> String {
        let dev = abs(score - threshold)
        if dev >= 0.3 { return "high" }
        if dev >= 0.15 { return "medium" }
        return "low"
    }

    /// Green (real) → yellow (uncertain) → red (generated).
    static func heat(_ p: Float) -> (Int, Int, Int) {
        func lerp(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ u: Float) -> (Int, Int, Int) {
            (Int(Float(a.0) + (Float(b.0) - Float(a.0)) * u), Int(Float(a.1) + (Float(b.1) - Float(a.1)) * u), Int(Float(a.2) + (Float(b.2) - Float(a.2)) * u))
        }
        let t = max(0, min(1, p))
        return t < 0.5 ? lerp((35, 150, 65), (214, 175, 40), t * 2) : lerp((214, 175, 40), (205, 55, 48), (t - 0.5) * 2)
    }

    static func weightColor(_ frac: Float) -> (Int, Int, Int) {
        let t = max(0, min(1, frac))
        return (Int(25 + 35 * t), Int(35 + 90 * t), Int(55 + 180 * t))
    }

    static func cell(_ text: String, bg: (Int, Int, Int), color: Bool) -> String {
        guard color else { return text }
        let lum = 0.299 * Double(bg.0) + 0.587 * Double(bg.1) + 0.114 * Double(bg.2)
        return "\u{1B}[48;2;\(bg.0);\(bg.1);\(bg.2)m\u{1B}[\(lum > 145 ? "30" : "97")m\(text)\u{1B}[0m"
    }

    static func word(_ word: String, color: Bool) -> String {
        guard color else { return word }
        let code: String
        switch word {
        case "generated": code = "31"
        case "inconclusive", "render": code = "33"
        default: code = "32"
        }
        return "\u{1B}[\(code);1m\(word)\u{1B}[0m"
    }

    static func sourceLabel(_ source: ResultSource) -> String {
        switch source {
        case .warpSensor: return "warp sensor"
        case .screenshotContent: return "screenshot content"
        case .semanticTiles: return "semantic tiles"
        case .none: return "none"
        }
    }

    static func majorityDetail(_ source: ResultSource) -> String {
        switch source {
        case .warpSensor: return "the camera-sensor score under its contract: as shipped, the tile vote itself, called by two cuts"
        case .screenshotContent: return "the screenshot content head's probability"
        case .semanticTiles: return "the semantic token vote (legacy payload)"
        case .none: return "source unavailable"
        }
    }

    static func render(_ r: InferenceResult, imagePath: String, model: String, times: [Double], device: String, color: Bool) -> String {
        var out = "VeilGarde — \(URL(fileURLWithPath: imagePath).lastPathComponent)\n"
        out += "image \(r.imageWidth)×\(r.imageHeight) · grid \(r.gridRows)×\(r.gridCols) @ \(r.patchSize) px · device \(device) · scorer \(r.scorer) · \(model)\n\n"
        var header = "     "
        for j in 0..<r.gridCols { header += String(format: "  %2d  ", j) }
        if r.tileMapSource != .none && r.patches.count >= r.gridRows * r.gridCols {
            out += "P(generated) [\(sourceLabel(r.tileMapSource)) map] — green real · yellow uncertain · red generated\n" + header + "\n"
            for i in 0..<r.gridRows {
                var line = String(format: " %2d  ", i)
                for j in 0..<r.gridCols {
                    let p = r.patches[i * r.gridCols + j].pGenerated
                    line += cell(String(format: " %3.0f%% ", p * 100), bg: heat(p), color: color)
                }
                out += line + "\n"
            }
            out += String(format: "\nbase-verdict contribution — %.1f%% shown (center × texture × confidence)\n", min(1, max(0, r.visibleBaseWeightShare)) * 100)
            out += header + "\n"
            let maxW = max(r.patches.map(\.weight).max() ?? 1, 1e-9)
            for i in 0..<r.gridRows {
                var line = String(format: " %2d  ", i)
                for j in 0..<r.gridCols {
                    let w = r.patches[i * r.gridCols + j].weight
                    line += cell(String(format: " %4.1f ", w * 100), bg: weightColor(w / maxW), color: color)
                }
                out += line + "\n"
            }
        } else {
            out += "tile map [none] — this route did not produce spatial sensor evidence\n"
        }
        if r.isScreenshot { out += "\nscreenshot/content route — no native camera-sensor map; the weighted verdict governs\n" }
        out += "\nverdict  weighted  \(String(format: "%.4f", r.weightedScore))  " + word(r.weightedPrediction, color: color)
        out += "  (\(confidence(r.weightedScore, threshold: r.decisionThreshold)) confidence" + String(format: " · T=%.2f ±%.2f)\n", r.decisionThreshold, r.uncertainBand)
        out += "         majority  \(String(format: "%.4f", r.majorityScore))  " + word(r.majorityPrediction, color: color)
        let trust = Trust.physicsVote(r)
        out += "  [\(sourceLabel(r.majoritySource)) · \(trust == "taxonomy" ? "taxonomy" : "\(trust) trust")]  (\(majorityDetail(r.majoritySource)))\n"
        if let raw = r.sensorRawProbability, r.majoritySource == .warpSensor {
            if let cuts = r.sensorCalibration?.cuts {
                out += String(format: "sensor   tile vote %.4f against two cuts: real at or under %.4f, generated at or over %.4f\n", raw, cuts.realAtOrBelow, cuts.generatedAtOrAbove)
            } else {
                out += String(format: "sensor   raw tile fraction %.4f → calibrated %.4f", raw, r.sensorProbability ?? raw) + " (\(r.sensorCalibration?.identity ?? "none"))\n"
            }
        }
        if let ns = r.nativeScore, let nd = r.nativeDisagreement {
            out += String(format: "native   weighted  %.4f  (center crop at native resolution · Δ %.4f%@)\n", ns, nd, nd > 0.08 ? " — DOMAIN SHIFT: resized and native scores disagree" : "")
        }
        if let cs = r.captureSignature {
            let tag: String
            if !cs.valid { tag = "abstain (native \(cs.nativePixels)px < 512 — too small or degraded to judge)" } else if cs.present { tag = "real-sensor signature PRESENT" } else { tag = "absent (generated, OR a degraded or shared real)" }
            let w = !cs.valid ? "inconclusive" : (cs.present ? "real" : "generated")
            out += String(format: "capture  peak %.1f  ", cs.peak) + word(w, color: color) + "  (\(tag))\n"
        }
        if let specialists = r.specialists, !specialists.isEmpty {
            out += "\nspecialists\n"
            for s in specialists {
                out += "  " + s.name.padding(toLength: 16, withPad: " ", startingAt: 0) + String(format: " P(AI) %.4f  ", s.pAI)
                    + word(s.verdict, color: color) + String(format: "  weight %.2f\n", s.weight)
            }
        }
        out += "time     " + times.enumerated().map { i, t in String(format: "%.3fs%@", t, i == 0 && times.count > 1 ? " (warmup)" : "") }.joined(separator: " · ") + "\n"
        return out
    }
}
