//
//  ResultJSONTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The routed result and the schema-v3 JSON: a routed result keeps the base expert's scorer,
//        operating point and size around the router's verdict and evidence; the JSON writes exactly
//        the v3 keys, omits the blocks a result lacks, and writes the same bytes for the same
//        result; only `.control` commits a semantic probe; the strict batch manifest.
//

import Foundation
import Testing
@testable import VeilGardeCore

private func baseResult(capture: CaptureSignature? = CaptureSignature(peak: 42, valid: true, nativePixels: 1_024, present: true)) -> InferenceResult {
    InferenceResult(scorer: "fusion", prediction: "real", p: 0.10, threshold: 0.5, band: 0.04, imageWidth: 640, imageHeight: 480, captureSignature: capture)
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let diagnostics = RouteDiagnostics(route: "camera", requestedHint: nil, semanticProfile: "control", screenshotGate: false, baseP: 0.42,
                                           preSemanticP: 0.61, preSemanticPrediction: "generated", semanticMajority: 0.99, semanticEvaluated: true,
                                           semanticTriggered: true)
private let hashes = BundleHashes(fusionHeadSHA256: "aa", combinerSHA256: "bb", manifestSHA256: "cc")

@Suite("Result JSON")
struct ResultJSONTests {
    @Test("a routed result keeps the base's scorer, operating point and size around the router's verdict")
    func routedKeepsBaseAndTrace() {
        let base = baseResult()
        let specialists = [SpecialistContribution(name: "fusion", pAI: 0.42, verdict: "real", weight: 1)]
        let r = PublicSurface.routed(base: base, prediction: "generated", p: 0.91, capture: base.captureSignature!, specialists: specialists,
                                     semanticTiles: [[0.99, 0.98]], routeDiagnostics: diagnostics, bundle: hashes)
        #expect(r.scorer == "fusion" && r.threshold == 0.5 && r.band == 0.04 && r.imageWidth == 640 && r.imageHeight == 480)
        #expect(r.prediction == "generated" && r.p == 0.91)
        #expect(r.specialists == specialists && r.semanticTiles == [[0.99, 0.98]] && r.routeDiagnostics == diagnostics && r.bundle == hashes)
    }

    @Test("the JSON writes exactly the schema-v3 keys")
    func jsonV3() throws {
        let base = baseResult()
        let r = PublicSurface.routed(base: base, prediction: "generated", p: 0.91, capture: base.captureSignature!,
                                     specialists: [SpecialistContribution(name: "art", pAI: 0.7, verdict: "generated", weight: 0.25)],
                                     semanticTiles: [[0.99, 0.0]], routeDiagnostics: diagnostics, bundle: hashes)
        let json = try object(ResultJSON.encode(r, times: [], device: "route", route: "camera"))
        #expect(Set(json.keys) == ["bundle", "capture", "device", "image", "route", "route_diagnostics", "schema_version", "scorer", "semantic_tiles",
                                   "specialists", "times_sec", "verdict"])
        #expect(json["schema_version"] as? Int == 3 && json["route"] as? String == "camera" && json["scorer"] as? String == "fusion")
        let verdict = try #require(json["verdict"] as? [String: Any])
        #expect(Set(verdict.keys) == ["band", "p", "prediction", "threshold"])
        #expect(verdict["prediction"] as? String == "generated" && abs((verdict["p"] as? Double ?? 0) - 0.91) < 1e-6)
        let d = try #require(json["route_diagnostics"] as? [String: Any])
        #expect(Set(d.keys) == ["route", "requested_hint", "semantic_profile", "screenshot_gate", "base_p", "pre_semantic_p", "pre_semantic_prediction",
                                "semantic_majority", "semantic_evaluated", "semantic_triggered", "semantic_decisive", "preview_evaluated",
                                "preview_triggered", "preview_decisive"])
        #expect(abs((d["base_p"] as? Double ?? 0) - 0.42) < 1e-6 && d["screenshot_gate"] as? Bool == false && d["requested_hint"] is NSNull)
        #expect((json["bundle"] as? [String: Any])?["fusion_head_sha256"] as? String == "aa")
        #expect((json["capture"] as? [String: Any])?["present"] as? Bool == true)
        #expect((json["image"] as? [String: Any])?["width"] as? Int == 640)
        #expect(((json["specialists"] as? [[String: Any]])?.first)?["name"] as? String == "art")
    }

    @Test("a result without capture, tiles, specialists, diagnostics or bundle omits those blocks, and the same result writes the same bytes")
    func jsonOmitsAbsentBlocks() throws {
        let bare = baseResult(capture: nil)
        let json = try object(ResultJSON.encode(bare, times: [0.5], device: "gpu"))
        #expect(Set(json.keys) == ["device", "image", "route", "schema_version", "scorer", "times_sec", "verdict"])
        #expect(json["route"] is NSNull)
        #expect(try ResultJSON.encode(bare, times: [0.5], device: "gpu") == ResultJSON.encode(bare, times: [0.5], device: "gpu"))
    }

    @Test("only the control profile commits a semantic probe")
    func semanticProfiles() {
        let control = PublicSurface.project(profile: .control, originalP: 0.20, originalVerdict: "real", probeP: 0.90, probeVerdict: "generated", probeDecisive: true)
        #expect(control == SemanticProjection(p: 0.90, verdict: "generated", decisive: true))
        for profile in [SemanticResponsibility.semanticDiagnosticOnly, .semanticRemoved] {
            let projected = PublicSurface.project(profile: profile, originalP: 0.20, originalVerdict: "real", probeP: 0.90, probeVerdict: "generated", probeDecisive: true)
            #expect(projected == SemanticProjection(p: 0.20, verdict: "real", decisive: false))
        }
    }

    @Test("the semantic profiles' raw values are stable and round-trip")
    func rawValues() throws {
        #expect(SemanticResponsibility.semanticDiagnosticOnly.rawValue == "semantic_diagnostic_only")
        #expect(SemanticResponsibility.semanticRemoved.rawValue == "semantic_removed")
        #expect(try JSONDecoder().decode(SemanticResponsibility.self, from: JSONEncoder().encode(SemanticResponsibility.semanticRemoved)) == .semanticRemoved)
    }
}

@Suite("Route batch manifest")
struct RouteBatchTests {
    @Test("parses order and hints exactly")
    func parses() throws {
        let items = try RouteBatch.parse(Data("""
        {"id":"first","path":"/a.jpg","hint":"camera"}
        {"id":"second","path":"/b.png","hint":"screenshot"}
        """.utf8))
        #expect(items.map(\.id) == ["first", "second"] && items.map(\.hint) == [.camera, .screenshot])
    }

    @Test("rejects a duplicate id before inference")
    func duplicate() {
        #expect(throws: RouteBatchError.duplicateID(line: 2, id: "same")) {
            try RouteBatch.parse(Data("""
            {"id":"same","path":"/a.jpg","hint":"camera"}
            {"id":"same","path":"/b.jpg","hint":"camera"}
            """.utf8))
        }
    }

    @Test("rejects a bad id, hint or shape")
    func rejects() {
        #expect(throws: RouteBatchError.self) { try RouteBatch.parse(Data(#"{"id":"bad id ","path":"/a","hint":"camera"}"#.utf8)) }
        #expect(throws: RouteBatchError.self) { try RouteBatch.parse(Data(#"{"id":"a","path":"/a","hint":"auto"}"#.utf8)) }
        #expect(throws: RouteBatchError.self) { try RouteBatch.parse(Data(#"{"id":"a","path":"/a","hint":"camera","extra":1}"#.utf8)) }
    }
}
