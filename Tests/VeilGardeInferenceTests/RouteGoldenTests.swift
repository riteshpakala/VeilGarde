//
//  RouteGoldenTests.swift
//  VeilGardeInferenceTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The full detector against VeilGarde's own goldens (`veilgarde route --json` on the two
//        parity crops with the shipped bundle): every label and structural field equal, every
//        number within 1e-4 (DINOv2's matrix kernels move with Frigate's MLX revision by about
//        1e-5). The goldens were re-recorded in schema v1 on 2026-10-21 after the stack's numbers
//        were checked equal to the schema-v3 goldens', and the verdicts stay pinned here by value.
//        The members and revisions in order; the schema-v1 keys; the semantic tiles removed;
//        DINOv2 against the HF reference embeddings.
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
        /// The verdicts of 2026-10-21, as the schema-v3 goldens held them before the stack was a list.
        static let verdicts: [String: (p: Float, prediction: String)] = ["crop_ben": (0.1059354618191719, "real"), "crop_fox": (0.018225347623229027, "real")]

        @Test("the result matches the golden: labels exact, numbers within 1e-4", arguments: ["crop_ben", "crop_fox"])
        func routeJSON(name: String) throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.crop("\(name).png"))
            let result = try Detector.detect(cgImage: cg, config: InferenceConfig())
            let ours = try ResultJSON.encode(result, times: [], device: "route")
            let (worst, mismatches) = try compare(ours, Data(contentsOf: Fixture.crop("\(name).route.json")), tolerance: 1e-4)
            #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
            #expect(worst < 1e-4, "max |Δ| \(worst)")
            let pinned = try #require(Self.verdicts[name])
            #expect(abs(result.p - pinned.p) < 1e-4 && result.prediction == pinned.prediction)
            #expect(result.stack.map(\.name) == ["screenshot", "camera", "capture", "art", "blur", "human", "preview", "semantic-tiles"])
            #expect(result.revisions.map(\.name) == ["combiner", "frame-seam", "preview-tail"])
            #expect(result.revisions.revision("combiner")?.text("anchor") == "camera")
        }

        @Test("the result JSON is schema v1")
        func schemaV1() throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.crop("crop_fox.png"))
            let result = try Detector.detect(cgImage: cg, config: InferenceConfig())
            let json = try #require(JSONSerialization.jsonObject(with: ResultJSON.encode(result, times: [], device: "route")) as? [String: Any])
            #expect(Set(json.keys) == ["bundle", "device", "image", "revisions", "schema_version", "stack", "times_sec", "verdict"])
            #expect(json["schema_version"] as? Int == 1)
            #expect(result.imageWidth == cg.width && result.imageHeight == cg.height)
        }

        @Test("removing the semantic tiles runs no token head and the preview tail never arms")
        func semanticRemoved() throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.crop("crop_fox.png"))
            var config = InferenceConfig()
            config.semanticResponsibility = .semanticRemoved
            let r = try Detector.detect(cgImage: cg, config: config)
            #expect(r.stack.member("semantic-tiles") == nil)
            #expect(r.revisions.revision("preview-tail")?.applied == false && r.revisions.revision("preview-tail")?.flag("triggered") == false)
        }

        @Test("a pipeline declared in place runs only its members and revisions")
        func customPipeline() throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.crop("crop_ben.png"))
            let pipeline = Pipeline {
                Stack {
                    Screenshot()
                    Camera()
                    Capture()
                    for kind in HeadKind.combinerOrder { Specialist(kind) }
                }
                Revisions {
                    Combine()
                }
            }
            let r = try Detector.detect(cgImage: cg, config: InferenceConfig(), pipeline: pipeline)
            let shipped = try Detector.detect(cgImage: cg, config: InferenceConfig())
            #expect(r.stack.map(\.name) == ["screenshot", "camera", "capture", "art", "blur", "human"] && r.revisions.map(\.name) == ["combiner"])
            #expect(r.p == shipped.revisions.revision("combiner")?.p, "the combiner reads the same members either way")
            let missing = Pipeline {
                Stack {
                    Camera()
                    Capture()
                }
                Revisions {
                    Combine()
                }
            }
            #expect(throws: VeilGardeFailure.self, "the combiner needs its evidence members") { try Detector.detect(cgImage: cg, config: InferenceConfig(), pipeline: missing) }
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
