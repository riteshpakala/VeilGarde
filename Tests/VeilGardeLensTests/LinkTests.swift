//
//  LinkTests.swift
//  VeilGardeLensTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The module links and re-exports Core.
//

import Testing
import VeilGardeLens

@Suite("Lens links")
struct LensLinkTests {
    @Test func reExportsCore() { #expect(!VeilGardeVersion.string.isEmpty) }
}
