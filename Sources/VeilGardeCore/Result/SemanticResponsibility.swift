//
//  SemanticResponsibility.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: How much authority the semantic-tile and preview mechanisms have inside the router.
//  PIN:  Raw values are the `--semantic-profile` contract and the result JSON's `semantic_profile`.
//        Production is `.control`; the other two exist for same-binary replay and ablation.
//

public enum SemanticResponsibility: String, Sendable, Codable, Equatable, CaseIterable {
    /// Production: run the semantic mechanisms and let their calibrated decisive branches revise
    /// the verdict.
    case control
    /// Run every probe and report what armed, but never revise the verdict.
    case semanticDiagnosticOnly = "semantic_diagnostic_only"
    /// Do not load or run the semantic-tile and preview probes.
    case semanticRemoved = "semantic_removed"
}
