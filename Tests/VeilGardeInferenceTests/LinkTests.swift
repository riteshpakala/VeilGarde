//
//  LinkTests.swift
//  VeilGardeInferenceTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The module links and re-exports the layers below it.
//

import Testing
import VeilGardeInference

@Suite("Inference links")
struct InferenceLinkTests {
    @Test func reExportsCore() { #expect(!VeilGardeVersion.string.isEmpty) }
}
