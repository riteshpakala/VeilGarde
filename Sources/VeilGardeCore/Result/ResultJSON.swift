//
//  ResultJSON.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The result JSON, schema v1: the one contract `veilgarde route --json`, `batch` and the
//        battery read. The verdict, the image's size, every stack member's output, every
//        revision's record, the bundle's hashes.
//  PIN:  Numbers are Float widened to Double; JSONSerialization with .sortedKeys, so the same result
//        always writes the same bytes. Schema v1 (2026-10-21) is a clean break: the detector is a
//        stack of members and a list of revisions, and the result lists both. A member is
//        {"name", "p", "verdict", …its fields}; a revision is {"name", "applied", "p",
//        "prediction", …its fields}.
//

import Foundation

public enum ResultJSON {
    public static let schemaVersion = 1

    private static func float(_ value: Float?) -> Any {
        if let value { return Double(value) }
        return NSNull()
    }

    /// A field's value as JSON.
    static func json(_ detail: Detail) -> Any {
        switch detail {
        case .number(let v): return Double(v)
        case .flag(let v): return v
        case .text(let v): return v
        case .grid(let v): return v.map { $0.map { Double($0) } }
        case .map(let v): return v.mapValues { Double($0) }
        case .absent: return NSNull()
        }
    }

    static func object(_ output: MemberOutput) -> [String: Any] {
        var out: [String: Any] = ["name": output.name, "p": float(output.p), "verdict": output.verdict]
        for field in output.fields { out[field.key] = json(field.value) }
        return out
    }

    static func object(_ record: RevisionRecord) -> [String: Any] {
        var out: [String: Any] = ["name": record.name, "applied": record.applied, "p": Double(record.p), "prediction": record.prediction]
        for field in record.fields { out[field.key] = json(field.value) }
        return out
    }

    public static func encode(_ r: InferenceResult, times: [Double], device: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: object(r, times: times, device: device), options: [.sortedKeys])
    }

    /// The JSON object, before serialization.
    public static func object(_ r: InferenceResult, times: [Double], device: String) -> [String: Any] {
        var out: [String: Any] = [
            "schema_version": schemaVersion,
            "device": device,
            "image": ["width": r.imageWidth, "height": r.imageHeight],
            "verdict": ["prediction": r.prediction, "p": Double(r.p), "threshold": Double(r.threshold), "band": Double(r.band)],
            "stack": r.stack.map(object),
            "revisions": r.revisions.map(object),
            "times_sec": times,
        ]
        if let b = r.bundle {
            out["bundle"] = ["manifest_sha256": b.manifestSHA256, "artifacts": b.artifacts] as [String: Any]
        }
        return out
    }
}
