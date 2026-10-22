//
//  ResultJSONTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The result and its schema-v1 JSON: the JSON writes exactly the v1 keys, a member as its
//        name, p and verdict beside its own fields, a revision as its name, applied, p and
//        prediction beside its own, and the same result as the same bytes; only `.control`
//        commits a semantic probe; the strict batch manifest.
//

import Foundation
import Testing
@testable import VeilGardeCore

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let stack = [
    MemberOutput(name: "camera", p: 0.42, verdict: "real", fields: [Field("p_neutral", .number(0.2))]),
    MemberOutput(name: "capture", p: nil, verdict: "absent", fields: [Field("peak", .number(7)), Field("valid", .flag(true)), Field("present", .flag(false))]),
    MemberOutput(name: "semantic-tiles", p: 0.5, verdict: "real", fields: [Field("majority", .number(0.5)), Field("grid", .grid([[0.99, 0.0]]))]),
]
private let revisions = [
    RevisionRecord(name: "combiner", applied: true, p: 0.91, prediction: "generated",
                   fields: [Field("anchor", .text("camera")), Field("pooled", .number(0.91)), Field("influence", .map(["art": 1.5]))]),
    RevisionRecord(name: "frame-seam", applied: false, p: 0.91, prediction: "generated", fields: [Field("interior_p", .absent)]),
]
private let hashes = BundleHashes(manifestSHA256: "cc", artifacts: ["camera": "aa", "combiner": "bb"])

private func result(bundle: BundleHashes? = hashes) -> InferenceResult {
    InferenceResult(prediction: "generated", p: 0.91, threshold: 0.5, band: 0.04, imageWidth: 640, imageHeight: 480,
                    stack: stack, revisions: revisions, bundle: bundle)
}

@Suite("Result JSON")
struct ResultJSONTests {
    @Test("the JSON writes exactly the schema-v1 keys")
    func jsonV1() throws {
        let json = try object(ResultJSON.encode(result(), times: [], device: "route"))
        #expect(Set(json.keys) == ["bundle", "device", "image", "revisions", "schema_version", "stack", "times_sec", "verdict"])
        #expect(json["schema_version"] as? Int == 1 && json["device"] as? String == "route")
        let verdict = try #require(json["verdict"] as? [String: Any])
        #expect(Set(verdict.keys) == ["band", "p", "prediction", "threshold"])
        #expect(verdict["prediction"] as? String == "generated" && abs((verdict["p"] as? Double ?? 0) - 0.91) < 1e-6)
        #expect((json["image"] as? [String: Any])?["width"] as? Int == 640)
        let bundle = try #require(json["bundle"] as? [String: Any])
        #expect(Set(bundle.keys) == ["artifacts", "manifest_sha256"] && (bundle["artifacts"] as? [String: String])?["camera"] == "aa")
    }

    @Test("a member is its name, p and verdict beside its own fields; a revision its name, applied, p and prediction beside its own")
    func membersAndRevisions() throws {
        let json = try object(ResultJSON.encode(result(), times: [], device: "route"))
        let members = try #require(json["stack"] as? [[String: Any]])
        #expect(members.map { $0["name"] as? String } == ["camera", "capture", "semantic-tiles"])
        #expect(Set(members[0].keys) == ["name", "p", "verdict", "p_neutral"] && abs((members[0]["p_neutral"] as? Double ?? 0) - 0.2) < 1e-6)
        #expect(members[1]["p"] is NSNull && members[1]["present"] as? Bool == false)
        #expect((members[2]["grid"] as? [[Double]])?.first?.first.map { abs($0 - 0.99) < 1e-6 } == true)
        let records = try #require(json["revisions"] as? [[String: Any]])
        #expect(Set(records[0].keys) == ["name", "applied", "p", "prediction", "anchor", "pooled", "influence"])
        #expect(records[0]["anchor"] as? String == "camera" && (records[0]["influence"] as? [String: Double])?["art"] == 1.5)
        #expect(records[1]["applied"] as? Bool == false && records[1]["interior_p"] is NSNull)
    }

    @Test("a result without a bundle omits that block, and the same result writes the same bytes")
    func jsonOmitsBundle() throws {
        let bare = result(bundle: nil)
        let json = try object(ResultJSON.encode(bare, times: [0.5], device: "gpu"))
        #expect(Set(json.keys) == ["device", "image", "revisions", "schema_version", "stack", "times_sec", "verdict"])
        #expect(try ResultJSON.encode(bare, times: [0.5], device: "gpu") == ResultJSON.encode(bare, times: [0.5], device: "gpu"))
    }

    @Test("a member reads its fields back by key, and the stack finds a member by name")
    func accessors() {
        #expect(stack.member("capture")?.flag("valid") == true && stack.member("camera")?.number("p_neutral") == 0.2)
        #expect(stack.member("semantic-tiles")?.grid("grid") == [[0.99, 0.0]] && stack.member("art") == nil)
        #expect(revisions.revision("combiner")?.text("anchor") == "camera")
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
    @Test("parses order exactly")
    func parses() throws {
        let items = try RouteBatch.parse(Data("""
        {"id":"first","path":"/a.jpg"}
        {"id":"second","path":"/b.png"}
        """.utf8))
        #expect(items.map(\.id) == ["first", "second"] && items.map(\.path) == ["/a.jpg", "/b.png"])
    }

    @Test("rejects a duplicate id before inference")
    func duplicate() {
        #expect(throws: RouteBatchError.duplicateID(line: 2, id: "same")) {
            try RouteBatch.parse(Data("""
            {"id":"same","path":"/a.jpg"}
            {"id":"same","path":"/b.jpg"}
            """.utf8))
        }
    }

    @Test("rejects a bad id or shape, a hint among them")
    func rejects() {
        #expect(throws: RouteBatchError.self) { try RouteBatch.parse(Data(#"{"id":"bad id ","path":"/a"}"#.utf8)) }
        #expect(throws: RouteBatchError.self) { try RouteBatch.parse(Data(#"{"id":"a","path":"/a","hint":"camera"}"#.utf8)) }
        #expect(throws: RouteBatchError.self) { try RouteBatch.parse(Data(#"{"id":"a"}"#.utf8)) }
    }
}
