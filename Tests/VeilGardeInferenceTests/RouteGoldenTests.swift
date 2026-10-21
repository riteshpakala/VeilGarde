//
//  RouteGoldenTests.swift
//  VeilGardeInferenceTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The full detector against VeilGarde's own route goldens (`veilgarde route --json` on the
//        two parity crops with the shipped bundle of 2026-10-21): every label, route and structural
//        field equal, every number within 1e-4 (DINOv2's matrix kernels move with Frigate's MLX
//        revision by about 1e-5). The schema-v3 keys; the screenshot hint; the semantic chain
//        removed; DINOv2 against the HF reference embeddings.
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

/// Labels exact, numbers within `tolerance`, times_sec aside; returns the worst numeric difference and
/// any mismatches.
func compare(_ a: Data, _ b: Data, tolerance: Double) throws -> (worst: Double, mismatches: [String]) {
    let kept: ((String, Any)) -> Bool = { !$0.0.hasPrefix("times_sec") }
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
    @Suite("Full detector goldens", .serialized, .enabled(if: Fixture.weightsPresent))
    struct RouteGoldenTests {
        @Test("the routed result matches the golden: labels exact, numbers within 1e-4", arguments: ["crop_ben", "crop_fox"])
        func routeJSON(name: String) throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.crop("\(name).png"))
            let routed = try Detector.shared.detect(cgImage: cg, config: InferenceConfig())
            #expect(routed.domain == .camera)
            let ours = try ResultJSON.encode(routed.result, times: [], device: "route", route: routed.domain.rawValue)
            let (worst, mismatches) = try compare(ours, Data(contentsOf: Fixture.crop("\(name).route.json")), tolerance: 1e-4)
            #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
            #expect(worst < 1e-4, "max |Δ| \(worst)")
            #expect(routed.result.specialists?.map(\.name) == ["fusion", "art", "blur", "human", "capture", "semantic-tiles"])
        }

        @Test("the result JSON is schema v3")
        func schemaV3() throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.crop("crop_fox.png"))
            let routed = try Detector.shared.detect(cgImage: cg, config: InferenceConfig())
            let json = try #require(JSONSerialization.jsonObject(with: ResultJSON.encode(routed.result, times: [], device: "route", route: "camera")) as? [String: Any])
            #expect(Set(json.keys) == ["bundle", "capture", "device", "image", "route", "route_diagnostics", "schema_version", "scorer", "semantic_tiles",
                                       "specialists", "times_sec", "verdict"])
            #expect(json["schema_version"] as? Int == 3 && json["scorer"] as? String == "fusion")
            #expect(routed.result.imageWidth == cg.width && routed.result.imageHeight == cg.height)
        }

        @Test("a screenshot hint routes to the content head")
        func screenshotHint() throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.crop("crop_ben.png"))
            let routed = try Detector.shared.detect(cgImage: cg, config: InferenceConfig(), hint: .screenshot)
            #expect(routed.domain == .screenshot)
            #expect(routed.result.scorer == "screenshot")
            #expect(routed.result.routeDiagnostics?.requestedHint == "screenshot" && routed.result.routeDiagnostics?.route == "screenshot")
        }

        @Test("removing the semantic chain runs no semantic probe")
        func semanticRemoved() throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.crop("crop_fox.png"))
            var config = InferenceConfig()
            config.semanticResponsibility = .semanticRemoved
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
