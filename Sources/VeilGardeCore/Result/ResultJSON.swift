//
//  ResultJSON.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The result JSON, schema v3: the one contract `veilgarde route --json`, `batch` and the
//        battery read. One verdict, the capture signature, the specialists, the semantic tiles, the
//        route trace and the bundle's hashes.
//  PIN:  Numbers are Float widened to Double; JSONSerialization with .sortedKeys, so the same result
//        always writes the same bytes. Schema v3 (2026-10-21) dropped every field the warp lens fed:
//        the majority lane, the camera-sensor score and its calibration, the tile and weight maps,
//        the native check and the warp models' hashes.
//

import Foundation

public enum ResultJSON {
    public static let schemaVersion = 3

    private static func float(_ value: Float?) -> Any {
        if let value { return Double(value) }
        return NSNull()
    }

    private static func string(_ value: String?) -> Any {
        if let value { return value }
        return NSNull()
    }

    public static func encode(_ r: InferenceResult, times: [Double], device: String, route: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: object(r, times: times, device: device, route: route), options: [.sortedKeys])
    }

    /// The JSON object, before serialization (the Flywheel's battery reads fields from it).
    public static func object(_ r: InferenceResult, times: [Double], device: String, route: String? = nil) -> [String: Any] {
        var out: [String: Any] = [
            "schema_version": schemaVersion,
            "route": string(route ?? r.routeDiagnostics?.route),
            "scorer": r.scorer,
            "device": device,
            "image": ["width": r.imageWidth, "height": r.imageHeight],
            "verdict": ["prediction": r.prediction, "p": Double(r.p), "threshold": Double(r.threshold), "band": Double(r.band)],
            "times_sec": times,
        ]
        if let b = r.bundle {
            out["bundle"] = ["fusion_head_sha256": string(b.fusionHeadSHA256), "combiner_sha256": string(b.combinerSHA256),
                             "manifest_sha256": b.manifestSHA256]
        }
        if let d = r.routeDiagnostics {
            out["route_diagnostics"] = [
                "route": d.route,
                "requested_hint": string(d.requestedHint),
                "semantic_profile": d.semanticProfile,
                "screenshot_gate": d.screenshotGate,
                "base_p": Double(d.baseP),
                "pre_semantic_p": Double(d.preSemanticP),
                "pre_semantic_prediction": d.preSemanticPrediction,
                "semantic_majority": float(d.semanticMajority),
                "semantic_evaluated": d.semanticEvaluated,
                "semantic_triggered": d.semanticTriggered,
                "semantic_decisive": d.semanticDecisive,
                "preview_evaluated": d.previewEvaluated,
                "preview_triggered": d.previewTriggered,
                "preview_decisive": d.previewDecisive,
            ] as [String: Any]
        }
        if let st = r.semanticTiles {
            out["semantic_tiles"] = st.map { $0.map { Double($0) } }
        }
        if let cs = r.captureSignature {
            out["capture"] = ["peak": Double(cs.peak), "valid": cs.valid, "native_px": cs.nativePixels, "present": cs.present]
        }
        if let specialists = r.specialists {
            out["specialists"] = specialists.map { s in
                ["name": s.name, "p_ai": Double(s.pAI), "verdict": s.verdict, "weight": Double(s.weight)] as [String: Any]
            }
        }
        return out
    }
}
