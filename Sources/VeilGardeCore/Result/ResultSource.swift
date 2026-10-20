//
//  ResultSource.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Provenance for what a result surfaces, and the campaign switches that choose it: which
//        evidence lane owns the public majority and tile map (the warp sensor, the screenshot
//        content head, the semantic tiles), how much authority the semantic chain has, and which
//        historical surface is public.
//  PIN:  Raw values are part of the result JSON and the campaign CLI contract. Production is
//        `.control` + `.warpSensor`; the others exist for same-binary replay and ablation.
//

public enum ResultSource: String, Sendable, Codable, Equatable {
    case warpSensor = "warp-sensor"
    case screenshotContent = "screenshot-content"
    case semanticTiles = "semantic-tiles"
    case none = "none"
}

/// How much authority the semantic-tile and preview mechanisms have inside the router.
public enum SemanticResponsibility: String, Sendable, Codable, Equatable, CaseIterable {
    /// Production: run the semantic mechanisms and let their calibrated decisive branches revise
    /// the weighted verdict.
    case control
    /// Run every probe and report what armed, but never revise the weighted verdict.
    case semanticDiagnosticOnly = "semantic_diagnostic_only"
    /// Do not load or run the semantic-tile, zoom, render, domain or preview probes.
    case semanticRemoved = "semantic_removed"
}

/// Which lane owns the public majority and tile map. `.legacySemantic` exists only to replay the
/// pre-Stage-1 semantic surface.
public enum ResultSurface: String, Sendable, Codable, Equatable, CaseIterable {
    case warpSensor = "warp-sensor"
    case legacySemantic = "legacy-semantic"
}
