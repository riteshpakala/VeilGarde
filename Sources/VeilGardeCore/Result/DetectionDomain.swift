//
//  DetectionDomain.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The domains the router knows, each with its own base expert: camera (the fusion head
//        over DINOv2 and the capture signature) and screenshot (a DINOv2 content head, because a
//        camera-anchored base false-fires on recompressed reels).
//  PIN:  Raw values are the result JSON's `route` and the batch manifest's `hint`.
//

public enum DetectionDomain: String, Sendable, Codable, Equatable, CaseIterable {
    case camera
    case screenshot
}

/// One specialist's say in a stacked verdict, surfaced so a reader can see which specialists ran
/// and what each said. `weight` is its influence on the final call: 1 decisive or firing, 0.25
/// consulted, 0 informational.
public struct SpecialistContribution: Sendable, Equatable {
    public let name: String
    public let pAI: Float
    public let verdict: String
    public let weight: Float

    public init(name: String, pAI: Float, verdict: String, weight: Float) {
        self.name = name
        self.pAI = pAI
        self.verdict = verdict
        self.weight = weight
    }
}
