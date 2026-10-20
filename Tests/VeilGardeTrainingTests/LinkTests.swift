//
//  LinkTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The module links and re-exports the layers below it.
//

import Testing
import VeilGardeTraining

@Suite("Training links")
struct TrainingLinkTests {
    @Test func reExportsCore() { #expect(!VeilGardeVersion.string.isEmpty) }
}
