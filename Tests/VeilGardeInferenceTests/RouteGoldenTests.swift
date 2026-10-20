//
//  RouteGoldenTests.swift
//  VeilGardeInferenceTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The full detector against Garde's headless `--route-json` goldens (2026-10-19):
//        every label, source, route and structural field equal, every number within 1e-4, but for
//        the sensor fields the two cuts changed on purpose (ResultJSON.changedSinceGarde), whose call
//        is still Garde's. Under Garde's own Metal library the bytes were identical (37 of 37 on
//        2026-10-19); under Frigate's current one DINOv2's GEMM kernels move its outputs by about
//        1e-5. Also DINOv2 against the HF reference embeddings, and the router's domain choice.
//

import Foundation
import Testing
@testable import VeilGardeInference

/// Every leaf of a JSON value with its path.
func leaves(_ value: Any, _ path: String = "") -> [(String, Any)] {
    if let d = value as? [String: Any] { return d.keys.sorted().flatMap { leaves(d[$0]!, path.isEmpty ? $0 : "\(path).\($0)") } }
    if let a = value as? [Any] { return a.enumerated().flatMap { leaves($1, "\(path)[\($0)]") } }
    return [(path, value)]
}

/// Labels exact, numbers within `tolerance`, the fields changed since Garde aside; returns the worst numeric
/// difference and any mismatches.
func compare(_ a: Data, _ b: Data, tolerance: Double) throws -> (worst: Double, mismatches: [String]) {
    let kept: ((String, Any)) -> Bool = { !$0.0.hasPrefix("times_sec") && !ResultJSON.changedSinceGarde($0.0) }
    let x = Dictionary(uniqueKeysWithValues: leaves(try JSONSerialization.jsonObject(with: a)).filter(kept))
    let y = Dictionary(uniqueKeysWithValues: leaves(try JSONSerialization.jsonObject(with: b)).filter(kept))
    var worst = 0.0
    var mismatches = Array(Set(x.keys).symmetricDifference(y.keys)).sorted()
    for key in Set(x.keys).intersection(y.keys) {
        if let m = x[key] as? NSNumber, let n = y[key] as? NSNumber, CFGetTypeID(m) != CFBooleanGetTypeID() {
            let d = abs(m.doubleValue - n.doubleValue)
            worst = max(worst, d)
            if d > tolerance { mismatches.append("\(key): \(m) vs \(n)") }
        } else if "\(x[key]!)" != "\(y[key]!)" {
            mismatches.append("\(key): \(x[key]!) vs \(y[key]!)")
        }
    }
    return (worst, mismatches)
}

extension InferenceMLXSuites {
    @Suite("Full detector goldens from Garde", .serialized, .enabled(if: Fixture.weightsPresent))
    struct RouteGoldenTests {
        @Test("the routed result matches Garde's: labels exact, numbers within 1e-4", arguments: ["crop_ben", "crop_fox"])
        func routeJSON(name: String) throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.garde("\(name).png"))
            let routed = try Detector.shared.detect(cgImage: cg, config: InferenceConfig())
            #expect(routed.domain == .camera)
            let ours = try ResultJSON.encode(routed.result, times: [], device: "route", route: routed.domain.rawValue)
            let (worst, mismatches) = try compare(ours, Data(contentsOf: Fixture.garde("\(name).route.json")), tolerance: 1e-4)
            #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
            #expect(worst < 1e-4, "max |Δ| \(worst)")
            #expect(routed.result.specialists?.map(\.name) == ["fusion", "art", "blur", "human", "sensor", "capture", "semantic-tiles"])
            // The sensor score is the tile vote itself now; its call is Garde's (compared above).
            #expect(routed.result.sensorProbability == routed.result.sensorRawProbability && routed.result.sensorCalibration?.transform == .cuts)
        }

        @Test("a screenshot hint routes to the content head, which has no warp grid")
        func screenshotHint() throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.garde("crop_ben.png"))
            let routed = try Detector.shared.detect(cgImage: cg, config: InferenceConfig(), hint: .screenshot)
            #expect(routed.domain == .screenshot)
            #expect(routed.result.scorer == "screenshot" && routed.result.majoritySource == .screenshotContent && routed.result.tileMapSource == .none)
            #expect(routed.result.routeDiagnostics?.requestedHint == "screenshot")
        }

        @Test("removing the semantic chain runs no semantic probe")
        func semanticRemoved() throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.garde("crop_fox.png"))
            var config = InferenceConfig()
            config.mechanisms.semanticResponsibility = .semanticRemoved
            let r = try Detector.shared.detect(cgImage: cg, config: config).result
            #expect(r.semanticTiles == nil && r.routeDiagnostics?.semanticEvaluated == false)
            #expect(!(r.specialists ?? []).contains { $0.name == "semantic-tiles" })
        }

        @Test("DINOv2 reproduces the HF reference embeddings (cosine ≥ 0.999)",
              .enabled(if: FileManager.default.fileExists(atPath: Fixture.parityDir.appendingPathComponent("dino_parity.safetensors").path)))
        func dinoParity() throws {
            let file = try SafetensorsFile(url: Fixture.parityDir.appendingPathComponent("dino_parity.safetensors"))
            let bases = Set(file.names.filter { $0.hasSuffix(".pixels") }.map { String($0.dropLast(7)) }).sorted()
            #expect(!bases.isEmpty)
            for base in bases {
                let emb = try SemanticLens.embedding(pixels: try file.float32("\(base).pixels"))
                let ref = try file.float32("\(base).emb")
                var dot: Float = 0, na: Float = 0, nb: Float = 0
                for i in 0..<emb.count { dot += emb[i] * ref[i]; na += emb[i] * emb[i]; nb += ref[i] * ref[i] }
                let cos = dot / (na.squareRoot() * nb.squareRoot())
                #expect(cos >= 0.999, "\(base): cosine \(cos)")
            }
        }
    }
}
