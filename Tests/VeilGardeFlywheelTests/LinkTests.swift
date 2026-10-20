//
//  LinkTests.swift
//  VeilGardeFlywheelTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The module links and re-exports the layers below it.
//

import Testing
import VeilGardeFlywheel

@Suite("Flywheel links")
struct FlywheelLinkTests {
    @Test func reExportsCore() { #expect(!VeilGardeVersion.string.isEmpty) }
}
