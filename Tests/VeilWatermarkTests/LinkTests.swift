//
//  LinkTests.swift
//  VeilWatermarkTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The module links and re-exports the layers below it.
//

import Testing
import VeilWatermark

@Suite("Watermark links")
struct WatermarkLinkTests {
    @Test func reExportsCore() { #expect(!VeilGardeVersion.string.isEmpty) }
}
