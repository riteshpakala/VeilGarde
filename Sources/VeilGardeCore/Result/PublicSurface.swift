//
//  PublicSurface.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The authority seam: which semantic profile may commit a revision the semantic tiles armed.
//  PIN:  Only `.control` commits it; the diagnostic and removed profiles observe a decisive probe
//        without changing the verdict.
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
    /// Diagnostic and removed profiles observe a decisive probe without changing the verdict.
    public static func project(profile: SemanticResponsibility, originalP: Float, originalVerdict: String,
                               probeP: Float, probeVerdict: String, probeDecisive: Bool) -> SemanticProjection {
        guard profile == .control else { return SemanticProjection(p: originalP, verdict: originalVerdict, decisive: false) }
        return SemanticProjection(p: probeP, verdict: probeVerdict, decisive: probeDecisive)
    }
}
