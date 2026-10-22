//
//  SemanticResponsibility.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: How much authority the semantic tiles and the preview tail have over the verdict.
//  PIN:  Raw values are the `--semantic-profile` contract.
//        Production is `.control`; the other two exist for same-binary replay and ablation.
//

public enum SemanticResponsibility: String, Sendable, Codable, Equatable, CaseIterable {
    /// Production: run the semantic tiles and let the preview tail's decisive branch revise the
    /// verdict.
    case control
    /// Run every probe and report what armed, but never revise the verdict.
    case semanticDiagnosticOnly = "semantic_diagnostic_only"
    /// Do not run the semantic tiles; the preview tail, which reads them, never arms.
    case semanticRemoved = "semantic_removed"
}
