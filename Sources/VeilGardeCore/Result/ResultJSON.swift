//
//  ResultJSON.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The canonical result JSON, schema v2: the one contract `veilgarde route --json`, the
//        battery and every downstream surface read. Verdict (majority with its trust, weighted),
//        calibration, the selected tile map and weight map, the sensor lane's tile vote and its call
//        with the contract's provenance, the capture signature, the specialists, the semantic tiles
//        and the route trace.
//  PIN:  Garde's result JSON moved, not rewritten: the same keys, the same Double conversions,
//        JSONSerialization with .sortedKeys. For the same InferenceResult under a Garde-era contract
//        the bytes are Garde's bytes (times_sec and device aside); the shipped two-cuts contract adds
//        its cuts to sensor_calibration and states its own schema (2) and comparison.
//

import Foundation

public enum ResultJSON {
    public static let schemaVersion = 2

    /// The fields in which this JSON differs from Garde's on purpose: the camera-sensor call is two cuts on the
    /// tile vote (the pruning study), so the sensor score is the vote itself and the contract is the cuts. The
    /// call is Garde's on every vote, and every other field is Garde's for the same image.
    public static let changedSinceGarde = ["sensor_p", "verdict.majority.score", "route_diagnostics.sensor_p",
                                           "sensor_calibration", "sensor_calibration_identity", "sensor_calibration_sha256"]

    /// True when a leaf's path (dotted, with [i] for an array item) is one of those fields or inside one.
    public static func changedSinceGarde(_ path: String) -> Bool {
        changedSinceGarde.contains { path == $0 || path.hasPrefix($0 + ".") || path.hasPrefix($0 + "[") }
    }

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
        var warpGrid = [[Double]](), warpWeights = [[Double]]()
        for i in 0..<r.gridRows {
            var row = [Double](), wrow = [Double]()
            for j in 0..<r.gridCols {
                let p = r.patches[i * r.gridCols + j]
                row.append(Double(p.pGenerated))
                wrow.append(Double(p.weight))
            }
            warpGrid.append(row)
            warpWeights.append(wrow)
        }
        var selectedGrid = warpGrid
        var selectedWeights = warpWeights
        var selectedRows = r.gridRows
        var selectedCols = r.gridCols
        var selectedPatchSize = r.patchSize
        if r.tileMapSource == .semanticTiles, let semantic = r.semanticTiles,
           let first = semantic.first, !semantic.isEmpty, !first.isEmpty,
           semantic.allSatisfy({ $0.count == first.count }) {
            selectedGrid = semantic.map { $0.map(Double.init) }
            selectedRows = semantic.count
            selectedCols = first.count
            selectedPatchSize = 224 / max(1, selectedCols)
            let equalVote = 1.0 / Double(max(1, selectedRows * selectedCols))
            selectedWeights = Array(repeating: Array(repeating: equalVote, count: selectedCols), count: selectedRows)
        }
        let resolvedRoute = route ?? r.routeDiagnostics?.route
        var out: [String: Any] = [
            "schema_version": schemaVersion,
            "majority_source": r.majoritySource.rawValue,
            "tile_map_source": r.tileMapSource.rawValue,
            "route": string(resolvedRoute),
            "sensor_raw_p": float(r.sensorRawProbability),
            "sensor_p": float(r.sensorProbability),
            "sensor_prediction": string(r.sensorPrediction),
            "sensor_trust": Trust.sensorVote(r, route: resolvedRoute),
            "base_model_sha256": string(r.baseWarpModelSHA256),
            "sensor_model_sha256": string(r.sensorWarpModelSHA256),
            "sensor_calibration_identity": string(r.sensorCalibration?.identity),
            "sensor_calibration_sha256": string(r.sensorCalibration?.provenanceSHA256),
            "device": device,
            "scorer": r.scorer,
            "patch_size": selectedPatchSize,
            "grid": ["rows": selectedRows, "cols": selectedCols],
            "image": ["width": r.imageWidth, "height": r.imageHeight],
            "verdict": [
                // On a warp-sensor route this is the calibrated sensor projection; sensor_raw_p keeps
                // the pre-calibration majority fraction.
                "majority": [
                    "prediction": r.majorityPrediction, "score": Double(r.majorityScore),
                    "trust": r.majoritySource == .warpSensor ? Trust.sensorVote(r, route: resolvedRoute) : Trust.physicsVote(r),
                ] as [String: Any],
                "weighted": ["prediction": r.weightedPrediction, "score": Double(r.weightedScore)],
            ],
            "calibration": [
                "decision_threshold": Double(r.decisionThreshold),
                "uncertain_band": Double(r.uncertainBand),
            ],
            "patch_scores": selectedGrid,
            "weight_map": selectedWeights,
            "times_sec": times,
        ]
        if let calibration = r.sensorCalibration {
            var sensorCalibration: [String: Any] = [
                "schema_version": calibration.schema,
                "identity": calibration.identity,
                "transform": calibration.transform.rawValue,
                "artifact_sha256": string(calibration.artifactSHA256),
                "provenance_sha256": calibration.provenanceSHA256,
                "sensor_variant": calibration.sensorVariant,
                "sensor_model_sha256": calibration.sensorModelSHA256,
                "score_semantics": SensorCalibrationContract.scoreSemantics,
                "decision_threshold": Double(calibration.decisionThreshold),
                "uncertain_band": Double(calibration.uncertainBand),
                "generated_comparison": calibration.comparison,
                "native_routes": calibration.nativeRoutes,
                "trust_law": SensorCalibrationContract.trustLaw,
            ]
            if let platt = calibration.plattPayload {
                sensorCalibration["platt_payload"] = ["coef": platt.coef, "intercept": platt.intercept]
            } else {
                sensorCalibration["platt_payload"] = NSNull()
            }
            if let cuts = calibration.cuts {
                sensorCalibration["cuts"] = ["real_at_or_below": cuts.realAtOrBelow, "generated_at_or_above": cuts.generatedAtOrAbove]
            }
            out["sensor_calibration"] = sensorCalibration
        }
        if let diagnostics = r.routeDiagnostics {
            out["route_diagnostics"] = [
                "route": diagnostics.route,
                "requested_hint": string(diagnostics.requestedHint),
                "semantic_profile": diagnostics.semanticProfile,
                "result_surface": diagnostics.resultSurface,
                "warp_p": float(diagnostics.warpP),
                "sensor_raw_p": float(diagnostics.sensorRawP),
                "sensor_p": float(diagnostics.sensorP),
                "sensor_prediction": string(diagnostics.sensorPrediction),
                "pre_semantic_p": float(diagnostics.preSemanticP),
                "pre_semantic_prediction": string(diagnostics.preSemanticPrediction),
                "semantic_majority": float(diagnostics.semanticMajority),
                "semantic_evaluated": diagnostics.semanticEvaluated,
                "semantic_triggered": diagnostics.semanticTriggered,
                "semantic_decisive": diagnostics.semanticDecisive,
                "preview_evaluated": diagnostics.previewEvaluated,
                "preview_triggered": diagnostics.previewTriggered,
                "preview_decisive": diagnostics.previewDecisive,
            ] as [String: Any]
        }
        if let ns = r.nativeScore, let nd = r.nativeDisagreement {
            out["native"] = ["score": Double(ns), "disagreement": Double(nd)]
        }
        // Semantic tile diagnostics (16×16 per-token P(generated)); `patch_scores` stays the
        // explicitly sourced product tile map.
        if let st = r.semanticTiles {
            out["semantic_tiles"] = st.map { $0.map { Double($0) } }
        }
        // The campaign-only legacy surface selects semantic tiles as patch_scores; these keep the
        // physical warp grid beside it.
        if r.tileMapSource == .semanticTiles {
            out["warp_patch_size"] = r.patchSize
            out["warp_grid"] = ["rows": r.gridRows, "cols": r.gridCols]
            out["warp_patch_scores"] = warpGrid
            out["warp_weight_map"] = warpWeights
            out["tile_map_coordinate_space"] = "dinov2-224-center-crop"
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
