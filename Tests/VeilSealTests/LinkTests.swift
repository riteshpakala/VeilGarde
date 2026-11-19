//
//  LinkTests.swift
//  VeilSealTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The module links and re-exports the layers below it.
//

import Testing
import VeilSeal

@Suite("Watermark links")
struct WatermarkLinkTests {
    @Test func reExportsCore() { #expect(!VeilGardeVersion.string.isEmpty) }
}
