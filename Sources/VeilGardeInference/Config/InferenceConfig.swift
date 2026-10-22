//
//  InferenceConfig.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: How one detection runs: the bundle it reads, the camera member's operating point, the
//        semantic backbone's size, and how much authority the semantic tiles have.
//  PIN:  The defaults are the shipped detector's: the shipped bundle, 0.5 ± 0.04, DINOv2-small and
//        the `.control` profile. The diagnostic and removed profiles are ablations.
//

import Foundation

public struct InferenceConfig: Sendable {
    /// The artifacts this detection reads (the shipped bundle unless told otherwise).
    public var bundle: DetectorBundle
    /// The camera member's operating point, 0.5 ± 0.04 (the screenshot member keeps its head's threshold with this band).
    public var decision: DecisionRule
    public var dinoVariant: DinoVariant
    /// Production `.control`; the diagnostic and removed profiles are ablations.
    public var semanticResponsibility: SemanticResponsibility
    /// The frame seam's recursion guard; never set by callers.
    public var skipFrameCheck: Bool

    public init(bundle: DetectorBundle = .shipped, decision: DecisionRule = .camera, dinoVariant: DinoVariant = .small,
                semanticResponsibility: SemanticResponsibility = .control) {
        self.bundle = bundle
        self.decision = decision
        self.dinoVariant = dinoVariant
        self.semanticResponsibility = semanticResponsibility
        self.skipFrameCheck = false
    }

    /// The shipped defaults.
    public static var shipped: InferenceConfig { InferenceConfig() }
}
