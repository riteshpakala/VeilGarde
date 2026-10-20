//
//  FlywheelResources.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The files the flywheel ships with: the battery spec (battery_spec_v2.json, the 8 groups
//        every promote is judged by) and the ratchet floors recorded for them
//        (battery_v2_baseline.json, v1's floors for those groups, unchanged); the category
//        router's prompt matrix (clip_prompts_v1.safetensors, from HF's CLIP text tower);
//        and the collector jobs that fill each blind spot (acquire_targets_v1.json, the Python
//        collectors' TARGET_MAP and default jobs).
//  PIN:  The flywheel's only Bundle.module (PackageLayeringTests). `flywheel init` copies these
//        into <work area>/battery/ (`flywheel init --battery` replaces an older pair there), and
//        the battery reads them there, so a rebaseline is a change to the work area, never to the
//        package. v2 (2026-10-19) retired v1's twelve atlas groups, whose images are gone.
//

import Foundation

public enum FlywheelResources {
    public static let batterySpecSHA256 = "83ae254ab7bbaf712787db39986705466f18248aeba1ee7dc39dcfe4047924d2"
    public static let batteryBaselineSHA256 = "1e711b66820d1b7b6a2e59dc46021551472781bd69b3a914f2e06ce796a6d41c"

    public static func url(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
            throw VeilGardeFailure.missing("the flywheel's \(name) is not in its resource bundle")
        }
        return url
    }

    public static func batterySpec() throws -> Data { try Data(contentsOf: url("battery_spec_v2.json")) }
    public static func batteryBaseline() throws -> Data { try Data(contentsOf: url("battery_v2_baseline.json")) }
}
