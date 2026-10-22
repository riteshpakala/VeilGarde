//
//  FeatureExtractor.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: One image to the store's three columns, the inputs every head, the camera head and the
//        combiner train on: dino_norm (the linear heads' 360×640 embedding), dino_fusion (the
//        camera head's plain embedding) and cap (nine capture values at native resolution).
//  PIN:  The detector's own calls in the detector's order (SemanticLens, CaptureLens), so a stored
//        row is what inference would compute for that image. The shard records which DINOv2
//        variant measured it and, when the weights are found, the first 12 hex of their SHA-256.
//        The image is read, used and dropped: nothing here writes it anywhere.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens

public struct ExtractedFeatures: Sendable, Equatable {
    public var dinoNorm: [Float]
    public var dinoFusion: [Float]
    public var cap: [Float]
    public var width: Int
    public var height: Int

    public init(dinoNorm: [Float], dinoFusion: [Float], cap: [Float], width: Int, height: Int) {
        self.dinoNorm = dinoNorm
        self.dinoFusion = dinoFusion
        self.cap = cap
        self.width = width
        self.height = height
    }

    public func values(_ column: FeatureColumn) -> [Float] {
        switch column {
        case .dinoNorm: return dinoNorm
        case .dinoFusion: return dinoFusion
        case .cap: return cap
        }
    }
}

/// What turns an image into a store row's columns: the extractor, or a stand-in in tests.
public protocol FeatureMeasuring: AnyObject {
    /// What measured the columns, for the shard's metadata.
    var provenance: [String: String] { get }
    func extract(_ cg: CGImage) throws -> ExtractedFeatures
}

public final class FeatureExtractor: FeatureMeasuring {
    public let variant: DinoVariant
    public let columns: Set<FeatureColumn>
    public let provenance: [String: String]

    public init(variant: DinoVariant = .small, columns: Set<FeatureColumn> = Set(FeatureColumn.allCases)) {
        self.variant = variant
        self.columns = columns
        var provenance = ["dino_variant": variant.rawValue]
        if let url = WeightLocator.shared.url(variant.weightFile), let sha = try? ContentHash.sha256Hex(fileAt: url) {
            provenance["dino_sha256_prefix"] = String(sha.prefix(12))
        }
        self.provenance = provenance
    }

    public func extract(_ cg: CGImage) throws -> ExtractedFeatures {
        let nan384 = [Float](repeating: .nan, count: 384)
        let dinoNorm = columns.contains(.dinoNorm) ? try SemanticLens.normalizedEmbedding(cg, variant: variant) : nan384
        let dinoFusion = columns.contains(.dinoFusion) ? try SemanticLens.fusionEmbedding(cg, variant: variant) : nan384
        let cap = columns.contains(.cap) ? CaptureLens.features(cg).asVector : [Float](repeating: .nan, count: CaptureFeatures.count)
        return ExtractedFeatures(dinoNorm: dinoNorm, dinoFusion: dinoFusion, cap: cap, width: cg.width, height: cg.height)
    }

    public func extract(contentsOf url: URL) throws -> ExtractedFeatures { try extract(try ImageDecoding.cgImage(contentsOf: url)) }
}
