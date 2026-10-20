//
//  HeadKind.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The specialist heads VeilGarde ships, by role: the screenshot domain's base expert, the three
//        atlas priors the combiner pools (art, blur, human), the pairwise real-art adjudicator,
//        and the arbiters the semantic chain consults (semantic tiles, cgi, preview).
//  PIN:  `combinerOrder` is the order StackCombiner.w_gen weighs: art, blur, human.
//

public enum HeadKind: String, Codable, Sendable, CaseIterable {
    case screenshot
    case art
    case blur
    case human
    case artPair = "art-pair"
    case semtile
    case cgi
    case preview

    /// The heads the stack combiner pools, in w_gen's order.
    public static let combinerOrder: [HeadKind] = [.art, .blur, .human]

    /// The heads the flywheel retrains every cycle (the weekly regime: art, blur, human, cgi).
    public static let flywheelCategories: [HeadKind] = [.art, .blur, .human, .cgi]

    /// The name a head row carries in `specialists[]`.
    public var specialistName: String { self == .artPair ? "art-pair" : rawValue }
}
