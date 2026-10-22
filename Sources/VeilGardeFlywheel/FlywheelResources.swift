//
//  FlywheelResources.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The files the flywheel ships with: the battery spec (battery_spec.json, version 1, the 8
//        groups every promote is judged by, four images the shipped detector misses set aside for
//        research) and the ratchet floors recorded for them (battery_baseline.json, recorded on
//        2026-10-21); the category router's prompt matrix
//        (clip_prompts_v1.safetensors, from HF's CLIP text tower); and the collector jobs that fill
//        each blind spot (acquire_targets_v1.json, the Python collectors' TARGET_MAP and default
//        jobs).
//  PIN:  The flywheel's only Bundle.module (PackageLayeringTests). `flywheel init` copies these
//        into <work area>/battery/ (`flywheel init --battery` replaces an older pair there), and
//        the battery reads them there, so a rebaseline is a change to the work area, never to the
//        package. Version 1 (2026-10-21) is the baseline for testing the stack: IMG_0291, IMG_0345,
//        IMG_0354 and HNUFoy2bcAA0vDW are set aside in staged[].
//

import Foundation

public enum FlywheelResources {
    public static let batterySpecSHA256 = "8aca4c2193935e3e72ae29eedbaaab74ace5445ab81995294a738181a108cde0"
    public static let batteryBaselineSHA256 = "53d170821081675f1cb03ce8dfe94a6a1b002d201f76e56fbdf0a6d562c4aca5"

    public static func url(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
            throw VeilGardeFailure.missing("the flywheel's \(name) is not in its resource bundle")
        }
        return url
    }

    public static func batterySpec() throws -> Data { try Data(contentsOf: url("battery_spec.json")) }
    public static func batteryBaseline() throws -> Data { try Data(contentsOf: url("battery_baseline.json")) }
}
