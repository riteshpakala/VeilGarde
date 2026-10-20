//
//  ResultSurfaceTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The public-surface laws and the schema-v2 JSON, ported from Garde's ResultSurfaceTests:
//        semantic diagnostics never replace the warp surface; a camera route surfaces the sensor
//        lane even when the screenshot guard owns the weighted verdict; trust never comes from an
//        optional grid or from agreeing abstentions; the scoring geometry and base-weight laws;
//        only `.control` commits a semantic probe; the legacy surface; the strict batch manifest.
//

import Foundation
import Testing
@testable import VeilGardeCore

private func baseResult(capture: CaptureSignature? = CaptureSignature(peak: 42, valid: true, nativePixels: 1_024, present: true),
                        patches: [PatchInfo]? = nil) -> InferenceResult {
    InferenceResult(
        majorityPrediction: "real", majorityScore: 0.25, weightedPrediction: "real", weightedScore: 0.10,
        patches: patches ?? [
            PatchInfo(row: 0, col: 0, pGenerated: 0.20, weight: 0.60, x: 0, y: 0, width: 32, height: 32),
            PatchInfo(row: 0, col: 1, pGenerated: 0.80, weight: 0.40, x: 32, y: 0, width: 32, height: 32),
        ],
        gridRows: 1, gridCols: 2, patchSize: 32, imageWidth: 64, imageHeight: 32,
        decisionThreshold: 0.56, uncertainBand: 0.05, nativeScore: nil, nativeDisagreement: nil,
        captureSignature: capture, majoritySource: .warpSensor, tileMapSource: .warpSensor)
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite("Result surface")
struct ResultSurfaceTests {
    @Test("routed semantic diagnostics cannot replace the warp surface")
    func semanticCannotReplaceWarp() {
        let base = baseResult()
        let result = PublicSurface.routed(
            base: base, weightedPrediction: "generated", weightedScore: 0.91, capture: base.captureSignature!, specialists: [],
            semanticTiles: [[0.99, 0.98]],
            routeDiagnostics: RouteDiagnostics(route: "camera", warpP: 0.42, sensorRawP: base.sensorRawProbability, sensorP: base.sensorProbability,
                                               sensorPrediction: base.sensorPrediction, semanticMajority: 0.99, semanticEvaluated: true, semanticTriggered: true))
        #expect(result.majorityPrediction == base.majorityPrediction)
        #expect(result.majorityScore == base.majorityScore)
        #expect(result.majoritySource == .warpSensor && result.tileMapSource == .warpSensor)
        #expect(result.patches.map(\.pGenerated) == base.patches.map(\.pGenerated))
        #expect(result.semanticTiles == [[0.99, 0.98]])
        #expect(result.sensorRawProbability == base.sensorRawProbability && result.sensorProbability == base.sensorProbability)
        #expect(result.sensorPrediction == base.sensorPrediction)
        #expect(result.routeDiagnostics?.route == "camera" && result.routeDiagnostics?.warpP == 0.42 && result.routeDiagnostics?.semanticTriggered == true)
        #expect(result.weightedPrediction == "generated" && result.weightedScore == 0.91)
    }

    @Test("a camera route surfaces the sensor lane even when the screenshot guard owns the weighted verdict")
    func cameraSurfaceOverridesScreenshotGuard() {
        let warp = baseResult()
        let guarded = InferenceResult(
            scorer: "screenshot", majorityPrediction: "generated", majorityScore: 0.88, weightedPrediction: "generated", weightedScore: 0.88,
            patches: warp.patches, gridRows: warp.gridRows, gridCols: warp.gridCols, patchSize: warp.patchSize,
            imageWidth: warp.imageWidth, imageHeight: warp.imageHeight, decisionThreshold: 0.5, uncertainBand: warp.uncertainBand,
            nativeScore: nil, nativeDisagreement: nil, captureSignature: warp.captureSignature, isScreenshot: true,
            majoritySource: .screenshotContent, tileMapSource: .warpSensor,
            sensorRawProbability: 0.70, sensorProbability: 0.77, sensorPrediction: "generated")
        let camera = PublicSurface.initial(base: guarded, domain: .camera, surface: .warpSensor)
        #expect(camera.prediction == "generated" && camera.score == 0.77 && camera.majoritySource == .warpSensor && camera.tileMapSource == .warpSensor)
        let screenshot = PublicSurface.initial(base: guarded, domain: .screenshot, surface: .warpSensor)
        #expect(screenshot.prediction == guarded.majorityPrediction && screenshot.score == guarded.majorityScore && screenshot.majoritySource == .screenshotContent)
        #expect(PublicSurface.initial(base: guarded, domain: .camera, surface: .legacySemantic).majoritySource == .screenshotContent)
    }

    @Test("the JSON adds provenance without removing the semantic diagnostics")
    func jsonProvenance() throws {
        let base = baseResult()
        let result = PublicSurface.routed(base: base, weightedPrediction: "real", weightedScore: 0.10, capture: base.captureSignature!,
                                          specialists: [], semanticTiles: [[0.99, 0.98]])
        let json = try object(ResultJSON.encode(result, times: [0.1], device: "test"))
        #expect(json["schema_version"] as? Int == 2)
        #expect(json["majority_source"] as? String == "warp-sensor" && json["tile_map_source"] as? String == "warp-sensor")
        let scores = try #require(json["patch_scores"] as? [[Double]])
        #expect(scores.count == 1 && abs(scores[0][0] - 0.20) < 1e-6 && abs(scores[0][1] - 0.80) < 1e-6)
        let semantic = try #require(json["semantic_tiles"] as? [[Double]])
        #expect(abs(semantic[0][0] - 0.99) < 1e-6 && abs(semantic[0][1] - 0.98) < 1e-6)
        let majority = try #require((json["verdict"] as? [String: Any])?["majority"] as? [String: Any])
        #expect(majority["score"] as? Double == 0.25 && majority["trust"] as? String == "high")
    }

    @Test("the route JSON exposes the sensor calibration and the diagnostics")
    func jsonSensorFields() throws {
        let modelHash = String(repeating: "a", count: 64), artifactHash = String(repeating: "b", count: 64)
        let calibration = try SensorCalibrationContract(sensorVariant: "warp40", sensorModelSHA256: modelHash, transform: .identity,
                                                        decisionThreshold: 0.60, uncertainBand: 0.04, nativeRoutes: ["camera"], artifactSHA256: artifactHash)
        let result = InferenceResult(
            majorityPrediction: "generated", majorityScore: 0.72, weightedPrediction: "generated", weightedScore: 0.91,
            patches: [PatchInfo(row: 0, col: 0, pGenerated: 0.8, weight: 1, x: 0, y: 0, width: 32, height: 32)],
            gridRows: 1, gridCols: 1, patchSize: 32, imageWidth: 32, imageHeight: 32, decisionThreshold: 0.56, uncertainBand: 0.04,
            nativeScore: nil, nativeDisagreement: nil, captureSignature: CaptureSignature(peak: 42, valid: true, nativePixels: 1_024, present: true),
            majoritySource: .warpSensor, tileMapSource: .warpSensor, sensorRawProbability: 0.68, sensorProbability: 0.72, sensorPrediction: "generated",
            sensorCalibration: calibration, baseWarpModelSHA256: String(repeating: "c", count: 64), sensorWarpModelSHA256: modelHash,
            routeDiagnostics: RouteDiagnostics(route: "camera", warpP: 0.83, sensorRawP: 0.68, sensorP: 0.72, sensorPrediction: "generated",
                                               semanticMajority: 0.77, semanticEvaluated: true, semanticTriggered: true, semanticDecisive: false,
                                               previewEvaluated: true, previewTriggered: false, previewDecisive: false))
        let json = try object(ResultJSON.encode(result, times: [0.1], device: "test", route: "camera"))
        #expect(json["route"] as? String == "camera")
        #expect(abs((json["sensor_raw_p"] as? Double ?? 0) - 0.68) < 1e-6 && abs((json["sensor_p"] as? Double ?? 0) - 0.72) < 1e-6)
        #expect(json["sensor_prediction"] as? String == "generated" && json["sensor_trust"] as? String == "high")
        #expect(json["base_model_sha256"] as? String == String(repeating: "c", count: 64) && json["sensor_model_sha256"] as? String == modelHash)
        #expect(json["sensor_calibration_identity"] as? String == "identity" && json["sensor_calibration_sha256"] as? String == artifactHash)
        let diagnostics = try #require(json["route_diagnostics"] as? [String: Any])
        #expect(abs((diagnostics["warp_p"] as? Double ?? 0) - 0.83) < 1e-6)
        #expect(diagnostics["semantic_evaluated"] as? Bool == true && diagnostics["preview_decisive"] as? Bool == false)
    }

    @Test("sensor trust rejects a non-native route and an abstention")
    func sensorTrust() throws {
        let calibration = try SensorCalibrationContract.identityFallback(sensorVariant: "warp19", sensorModelSHA256: String(repeating: "a", count: 64), uncertainBand: 0.04)
        func result(_ prediction: String) -> InferenceResult {
            InferenceResult(majorityPrediction: prediction, majorityScore: 0.5, weightedPrediction: "generated", weightedScore: 0.9, patches: [],
                            gridRows: 0, gridCols: 0, patchSize: 32, imageWidth: 1, imageHeight: 1, decisionThreshold: 0.56, uncertainBand: 0.04,
                            nativeScore: nil, nativeDisagreement: nil, captureSignature: CaptureSignature(peak: 42, valid: true, nativePixels: 1_024, present: true),
                            sensorRawProbability: 0.5, sensorProbability: 0.5, sensorPrediction: prediction, sensorCalibration: calibration)
        }
        #expect(Trust.sensorVote(result("generated"), route: "screenshot") == "low")
        #expect(Trust.sensorVote(result("inconclusive"), route: "camera") == "low")
        #expect(Trust.sensorVote(result("generated"), route: "camera") == "high")
    }

    @Test("warp trust never infers semantic provenance from an optional grid")
    func warpTrustIgnoresSemanticGrid() {
        let base = baseResult(capture: nil)
        let result = InferenceResult(majorityPrediction: base.majorityPrediction, majorityScore: base.majorityScore, weightedPrediction: base.weightedPrediction,
                                     weightedScore: base.weightedScore, patches: base.patches, gridRows: base.gridRows, gridCols: base.gridCols,
                                     patchSize: base.patchSize, imageWidth: base.imageWidth, imageHeight: base.imageHeight,
                                     decisionThreshold: base.decisionThreshold, uncertainBand: base.uncertainBand, nativeScore: nil, nativeDisagreement: nil,
                                     semanticTiles: [[0.01]], majoritySource: .warpSensor, tileMapSource: .warpSensor)
        #expect(Trust.physicsVote(result) == "low")
    }

    @Test("matching abstentions are never high trust", arguments: [ResultSource.warpSensor, .screenshotContent, .semanticTiles])
    func abstentions(source: ResultSource) {
        let result = InferenceResult(majorityPrediction: "inconclusive", majorityScore: 0.50, weightedPrediction: "inconclusive", weightedScore: 0.50,
                                     patches: [], gridRows: 0, gridCols: 0, patchSize: 0, imageWidth: 1, imageHeight: 1, decisionThreshold: 0.50,
                                     uncertainBand: 0.05, nativeScore: nil, nativeDisagreement: nil,
                                     captureSignature: CaptureSignature(peak: 42, valid: true, nativePixels: 1_024, present: true),
                                     majoritySource: source, tileMapSource: .none)
        #expect(Trust.physicsVote(result) == "low")
    }

    @Test("campaign raw values are stable and round-trip")
    func rawValues() throws {
        #expect(try JSONDecoder().decode(ResultSource.self, from: JSONEncoder().encode(ResultSource.warpSensor)) == .warpSensor)
        #expect(SemanticResponsibility.semanticDiagnosticOnly.rawValue == "semantic_diagnostic_only")
        #expect(SemanticResponsibility.semanticRemoved.rawValue == "semantic_removed")
        #expect(ResultSurface.legacySemantic.rawValue == "legacy-semantic")
        #expect(try JSONDecoder().decode(SemanticResponsibility.self, from: JSONEncoder().encode(SemanticResponsibility.semanticRemoved)) == .semanticRemoved)
    }

    @Test("directional scoring geometry keeps the remainder in the presentation canvas", arguments: [35, 40])
    func directionalGeometry(featureCount: Int) {
        let g = ScoringGeometry.make(realWidth: 512, realHeight: 341, paddedWidth: 512, paddedHeight: 352, featureCount: featureCount)
        #expect(g.imageWidth == 512 && g.imageHeight == 341 && g.scoringWidth == 512 && g.scoringHeight == 320)
    }

    @Test("scoring geometry keeps aligned and 19-column behaviour")
    func warp19Geometry() {
        #expect(ScoringGeometry.make(realWidth: 512, realHeight: 320, paddedWidth: 512, paddedHeight: 320, featureCount: 40)
                == ScoringGeometry(imageWidth: 512, imageHeight: 320, scoringWidth: 512, scoringHeight: 320))
        #expect(ScoringGeometry.make(realWidth: 512, realHeight: 341, paddedWidth: 512, paddedHeight: 352, featureCount: 19)
                == ScoringGeometry(imageWidth: 512, imageHeight: 341, scoringWidth: 512, scoringHeight: 352))
    }

    @Test("partial base-weight contributions are not renormalized")
    func partialWeights() {
        let baseWeights: [[Float]] = [[0.4, 0.1], [0.2, 0.3]]
        var partial: Float = 0
        for y in stride(from: 0, to: 96, by: 32) { for x in stride(from: 0, to: 96, by: 32) {
            partial += ScoringGeometry.baseWeightContribution(weightMap: baseWeights, x: x, y: y, basePatchSize: 64, sensorPatchSize: 32)
        } }
        #expect(abs(partial - 0.625) < 1e-6)
        var full: Float = 0
        for y in stride(from: 0, to: 128, by: 32) { for x in stride(from: 0, to: 128, by: 32) {
            full += ScoringGeometry.baseWeightContribution(weightMap: baseWeights, x: x, y: y, basePatchSize: 64, sensorPatchSize: 32)
        } }
        #expect(abs(full - 1) < 1e-6)
        let r = baseResult(patches: [PatchInfo(row: 0, col: 0, pGenerated: 0.20, weight: 0.25, x: 0, y: 0, width: 32, height: 32),
                                     PatchInfo(row: 0, col: 1, pGenerated: 0.80, weight: 0.375, x: 32, y: 0, width: 32, height: 32)])
        #expect(abs(r.visibleBaseWeightShare - 0.625) < 1e-6)
    }

    @Test("the sensor lane is the 32-px tile grid, never a presentation patch size")
    func sensorLane() {
        #expect(ScoringGeometry.baseGridIsSensorLane(patchSize: 32))
        for size in [64, 128, 256] { #expect(!ScoringGeometry.baseGridIsSensorLane(patchSize: size)) }
    }

    @Test("the unpadded plane covers only truncated signature grids")
    func signaturePlane() {
        #expect(ScoringGeometry.unpaddedPlaneCoversSignatureGrid(sigH: 341, sigW: 512, TR: 10, TC: 16))
        #expect(ScoringGeometry.unpaddedPlaneCoversSignatureGrid(sigH: 128, sigW: 512, TR: 4, TC: 16))
        #expect(!ScoringGeometry.unpaddedPlaneCoversSignatureGrid(sigH: 120, sigW: 512, TR: 4, TC: 16))
        #expect(!ScoringGeometry.unpaddedPlaneCoversSignatureGrid(sigH: 512, sigW: 120, TR: 16, TC: 4))
        #expect(ScoringGeometry.unpaddedPlaneCoversSignatureGrid(sigH: 128, sigW: 480, TR: 4, TC: 15))
        #expect(!ScoringGeometry.unpaddedPlaneCoversSignatureGrid(sigH: 127, sigW: 480, TR: 4, TC: 15))
        #expect(!ScoringGeometry.unpaddedPlaneCoversSignatureGrid(sigH: 0, sigW: 0, TR: 1, TC: 1))
    }

    @Test("a block-mean fraction diverges from the tile fraction at the operating point")
    func blockMeanDiverges() throws {
        let contract = try SensorCalibrationContract(sensorVariant: "warp19", sensorModelSHA256: String(repeating: "a", count: 64), transform: .platt,
                                                     plattPayload: SensorPlattPayload(coef: 0.48908749922126266, intercept: -0.09094760943132153),
                                                     decisionThreshold: 0.6298664647384551, uncertainBand: 0.04)
        var tiles = [[Float]](repeating: [Float](repeating: 0.51, count: 4), count: 4)
        for i in 0..<2 { for j in 0..<2 { tiles[i * 2][j * 2] = 0.20 } }
        let tileFraction = Float(tiles.flatMap { $0 }.filter { $0 > 0.5 }.count) / 16
        var blockMeans = [Float]()
        for i in stride(from: 0, to: 4, by: 2) { for j in stride(from: 0, to: 4, by: 2) {
            blockMeans.append((tiles[i][j] + tiles[i][j + 1] + tiles[i + 1][j] + tiles[i + 1][j + 1]) / 4)
        } }
        let blockFraction = Float(blockMeans.filter { $0 > 0.5 }.count) / Float(blockMeans.count)
        #expect(abs(tileFraction - 0.75) < 1e-6 && abs(blockFraction) < 1e-6)
        #expect(contract.prediction(for: contract.calibratedProbability(tileFraction)) == "inconclusive")
        #expect(contract.prediction(for: contract.calibratedProbability(blockFraction)) == "real")
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

    @Test("the legacy semantic label: render, then the domain gate, then coherence")
    func legacyLabel() {
        #expect(PublicSurface.legacySemanticPrediction(semanticVerdict: "generated", weightedVerdict: "real", renderFires: true, domainGated: true) == "render")
        #expect(PublicSurface.legacySemanticPrediction(semanticVerdict: "generated", weightedVerdict: "generated", renderFires: false, domainGated: true) == "inconclusive")
        #expect(PublicSurface.legacySemanticPrediction(semanticVerdict: "generated", weightedVerdict: "generated", renderFires: false, domainGated: false) == "generated")
        #expect(PublicSurface.legacySemanticPrediction(semanticVerdict: "generated", weightedVerdict: "real", renderFires: false, domainGated: false) == "inconclusive")
    }

    @Test("the legacy surface selects the semantic map and keeps the warp patches")
    func legacySurface() throws {
        let base = baseResult()
        let diagnostics = RouteDiagnostics(route: "camera", requestedHint: "camera", semanticProfile: SemanticResponsibility.semanticDiagnosticOnly.rawValue,
                                           resultSurface: ResultSurface.legacySemantic.rawValue, preSemanticP: 0.37, preSemanticPrediction: "real",
                                           semanticMajority: 1.0, semanticEvaluated: true, semanticTriggered: true, semanticDecisive: false)
        let result = PublicSurface.routed(base: base, weightedPrediction: "generated", weightedScore: 0.91, capture: base.captureSignature!, specialists: [],
                                          semanticTiles: [[0.99], [0.98]], majorityPrediction: "generated", majorityScore: 1.0,
                                          majoritySource: .semanticTiles, tileMapSource: .semanticTiles, routeDiagnostics: diagnostics)
        #expect(result.majoritySource == .semanticTiles && result.tileMapSource == .semanticTiles)
        #expect(result.patches.map(\.pGenerated) == base.patches.map(\.pGenerated))
        let json = try object(ResultJSON.encode(result, times: [], device: "test"))
        let grid = try #require(json["grid"] as? [String: Int])
        #expect(grid["rows"] == 2 && grid["cols"] == 1)
        #expect(abs((try #require(json["patch_scores"] as? [[Double]]))[0][0] - 0.99) < 1e-6)
        let warp = try #require(json["warp_patch_scores"] as? [[Double]])
        #expect(abs(warp[0][0] - 0.20) < 1e-6 && abs(warp[0][1] - 0.80) < 1e-6)
        let trace = try #require(json["route_diagnostics"] as? [String: Any])
        #expect(trace["requested_hint"] as? String == "camera" && trace["semantic_profile"] as? String == "semantic_diagnostic_only")
        #expect(trace["result_surface"] as? String == "legacy-semantic" && trace["pre_semantic_prediction"] as? String == "real")
        #expect(abs((trace["pre_semantic_p"] as? Double ?? 0) - 0.37) < 1e-6 && trace["semantic_decisive"] as? Bool == false)
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
