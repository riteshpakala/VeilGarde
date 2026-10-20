//
//  DinoVariant.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The DINOv2-small weight variants, smallest memory last: small (F32, 86 MB, the default),
//        xsmall (F16, 43 MB), xxsmall (8-bit Linear weights in groups of 64, 23 MB; conv, norms and
//        embeddings stay F16, and the model is quantized before its weights load).
//

public enum DinoVariant: String, Sendable, Codable, CaseIterable {
    case small, xsmall, xxsmall

    public var weightFile: WeightFile {
        switch self {
        case .small: return .dinov2Small
        case .xsmall: return .dinov2XSmall
        case .xxsmall: return .dinov2XXSmall
        }
    }

    public var isQuantized: Bool { self == .xxsmall }
    public var quantGroupSize: Int { 64 }
    public var quantBits: Int { 8 }
}
