//
//  PublicSurface.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The router's pure laws for what a result surfaces: which lane owns the public majority
//        before the semantic chain runs, how the legacy semantic surface labels a conflict, which
//        campaign profile may commit a probe's revision, and how a routed result is assembled
//        around the base lane's warp patches.
//  PIN:  Garde's initialPublicSurface, legacySemanticPrediction, semanticResponsibilityProjection
//        and stage1RoutedResult, unchanged. On a camera route under the warp-sensor surface the
//        public majority IS the calibrated sensor lane, even when the screenshot guard inside the
//        fusion owns the weighted verdict; only `.control` commits a semantic probe's revision.
//

public struct SemanticProjection: Equatable, Sendable {
    public let p: Float
    public let verdict: String
    public let decisive: Bool

    public init(p: Float, verdict: String, decisive: Bool) {
        self.p = p
        self.verdict = verdict
        self.decisive = decisive
    }
}

public enum PublicSurface {
    /// The public majority and map lane, chosen before any semantic diagnostics run.
    public static func initial(base: InferenceResult, domain: DetectionDomain, surface: ResultSurface)
        -> (prediction: String, score: Float, majoritySource: ResultSource, tileMapSource: ResultSource) {
        if surface == .warpSensor, domain == .camera, let sensorPrediction = base.sensorPrediction, let sensorProbability = base.sensorProbability {
            return (sensorPrediction, sensorProbability, .warpSensor, .warpSensor)
        }
        return (base.majorityPrediction, base.majorityScore, base.majoritySource, base.tileMapSource)
    }

    /// The legacy semantic surface's label: render beats the domain gate beats coherence.
    public static func legacySemanticPrediction(semanticVerdict: String, weightedVerdict: String, renderFires: Bool, domainGated: Bool) -> String {
        if renderFires { return "render" }
        if domainGated { return "inconclusive" }
        return semanticVerdict == weightedVerdict ? semanticVerdict : "inconclusive"
    }

    /// The authority seam: diagnostic and removed profiles observe a decisive probe without
    /// changing either stable weighted field.
    public static func project(profile: SemanticResponsibility, originalP: Float, originalVerdict: String,
                               probeP: Float, probeVerdict: String, probeDecisive: Bool) -> SemanticProjection {
        guard profile == .control else { return SemanticProjection(p: originalP, verdict: originalVerdict, decisive: false) }
        return SemanticProjection(p: probeP, verdict: probeVerdict, decisive: probeDecisive)
    }

    /// The routed result: the base lane's warp patches and sensor fields, the router's weighted
    /// verdict, and whichever majority/map lane the surface selected.
    public static func routed(base: InferenceResult, weightedPrediction: String, weightedScore: Float, capture: CaptureSignature,
                              specialists: [SpecialistContribution], semanticTiles: [[Float]]?, majorityPrediction: String? = nil,
                              majorityScore: Float? = nil, majoritySource: ResultSource? = nil, tileMapSource: ResultSource? = nil,
                              routeDiagnostics: RouteDiagnostics? = nil) -> InferenceResult {
        var routed = InferenceResult(
            scorer: base.scorer,
            majorityPrediction: majorityPrediction ?? base.majorityPrediction,
            majorityScore: majorityScore ?? base.majorityScore,
            weightedPrediction: weightedPrediction, weightedScore: weightedScore,
            patches: base.patches, gridRows: base.gridRows, gridCols: base.gridCols,
            patchSize: base.patchSize, imageWidth: base.imageWidth, imageHeight: base.imageHeight,
            decisionThreshold: base.decisionThreshold, uncertainBand: base.uncertainBand,
            nativeScore: base.nativeScore, nativeDisagreement: base.nativeDisagreement,
            captureSignature: capture, isScreenshot: base.isScreenshot, sharpness: base.sharpness,
            specialists: specialists, semanticTiles: semanticTiles,
            majoritySource: majoritySource ?? base.majoritySource,
            tileMapSource: tileMapSource ?? base.tileMapSource,
            sensorRawProbability: base.sensorRawProbability,
            sensorProbability: base.sensorProbability,
            sensorPrediction: base.sensorPrediction,
            sensorCalibration: base.sensorCalibration,
            baseWarpModelSHA256: base.baseWarpModelSHA256,
            sensorWarpModelSHA256: base.sensorWarpModelSHA256,
            routeDiagnostics: routeDiagnostics ?? base.routeDiagnostics)
        routed.warpWeightedScore = base.warpWeightedScore
        return routed
    }
}
