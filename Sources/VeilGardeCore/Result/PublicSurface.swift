//
//  PublicSurface.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The router's two pure laws for what a result surfaces: which semantic profile may commit a
//        probe's revision, and how a routed result is assembled around the base expert's.
//  PIN:  Only `.control` commits a semantic probe's revision; the diagnostic and removed profiles
//        observe a decisive probe without changing the verdict.
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
    /// The authority seam: diagnostic and removed profiles observe a decisive probe without
    /// changing the verdict.
    public static func project(profile: SemanticResponsibility, originalP: Float, originalVerdict: String,
                               probeP: Float, probeVerdict: String, probeDecisive: Bool) -> SemanticProjection {
        guard profile == .control else { return SemanticProjection(p: originalP, verdict: originalVerdict, decisive: false) }
        return SemanticProjection(p: probeP, verdict: probeVerdict, decisive: probeDecisive)
    }

    /// The routed result: the base expert's scorer, operating point and image size, the router's
    /// verdict, and the evidence and trace around it.
    public static func routed(base: InferenceResult, prediction: String, p: Float, capture: CaptureSignature,
                              specialists: [SpecialistContribution], semanticTiles: [[Float]]?,
                              routeDiagnostics: RouteDiagnostics, bundle: BundleHashes?) -> InferenceResult {
        InferenceResult(scorer: base.scorer, prediction: prediction, p: p, threshold: base.threshold, band: base.band,
                        imageWidth: base.imageWidth, imageHeight: base.imageHeight, captureSignature: capture,
                        specialists: specialists, semanticTiles: semanticTiles, routeDiagnostics: routeDiagnostics, bundle: bundle)
    }
}
