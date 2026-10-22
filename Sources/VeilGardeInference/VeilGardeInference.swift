//
//  VeilGardeInference.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The detector as one pipeline, Decode → Shared Signals → Stack → Revisions → Result: the
//        signals computed once, a stack of independent members (the screenshot gate and head, the
//        camera head, the capture signature, the specialist heads, the semantic tiles), the
//        revisions that read them (the combiner, the frame seam, the preview tail), one
//        InferenceResult and its schema-v1 JSON. Re-exports the Lens and Core.
//

@_exported import VeilGardeLens
