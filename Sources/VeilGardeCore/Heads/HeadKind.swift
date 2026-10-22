//
//  HeadKind.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The linear heads VeilGarde ships, by kind: the screenshot member's content head, the three
//        category heads the combiner pools (art, blur, human), the preview head the preview tail
//        reads, and the semantic-tile head on DINOv2's patch tokens.
//  PIN:  `combinerOrder` is the shipped combiner's evidence order: art, blur, human.
//

public enum HeadKind: String, Codable, Sendable, CaseIterable {
    case screenshot
    case art
    case blur
    case human
    case semtile
    case preview

    /// The heads the shipped combiner pools as evidence, in its order.
    public static let combinerOrder: [HeadKind] = [.art, .blur, .human]

    /// The heads the flywheel retrains every cycle: the three the combiner pools.
    public static let flywheelCategories: [HeadKind] = [.art, .blur, .human]
}
