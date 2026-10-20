//
//  FeatureExtractor.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: One image to the store's six columns, the inputs every head, the fusion head and the
//        combiner train on: dino_norm (the heads' 360×640 embedding), dino_fusion (the fusion
//        head's plain embedding), cap (nine capture values at native resolution), warp (the warp
//        lens's weighted score under a named warp model), sharp (three sharpness values) and
//        noiseprint (P(camera), NaN without its weights).
//  PIN:  The detector's own calls in the detector's order (SemanticLens, CaptureLens, WarpLens,
//        NoiseprintLens), so a stored row is what inference would compute for that image. The
//        warp column records which model computed it (the first 12 hex of its SHA-256). The image
//        is read, used and dropped: nothing here writes it anywhere.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens

public struct ExtractedFeatures: Sendable, Equatable {
    public var dinoNorm: [Float]
    public var dinoFusion: [Float]
    public var cap: [Float]
    public var warp: Float
    public var sharp: [Float]
    public var noiseprint: Float
    public var width: Int
    public var height: Int

    public init(dinoNorm: [Float], dinoFusion: [Float], cap: [Float], warp: Float, sharp: [Float], noiseprint: Float, width: Int, height: Int) {
        self.dinoNorm = dinoNorm
        self.dinoFusion = dinoFusion
        self.cap = cap
        self.warp = warp
        self.sharp = sharp
        self.noiseprint = noiseprint
        self.width = width
        self.height = height
    }

    public func values(_ column: FeatureColumn) -> [Float] {
        switch column {
        case .dinoNorm: return dinoNorm
        case .dinoFusion: return dinoFusion
        case .cap: return cap
        case .warp: return [warp]
        case .sharp: return sharp
        case .noiseprint: return [noiseprint]
        }
    }
}

/// What turns an image into a store row's columns: the extractor, or a stand-in in tests.
public protocol FeatureMeasuring: AnyObject {
    var warpModelTag: String { get }
    func extract(_ cg: CGImage) throws -> ExtractedFeatures
}

public final class FeatureExtractor: FeatureMeasuring {
    public let warpModelURL: URL
    public let warpModelTag: String
    public let variant: DinoVariant
    public let columns: Set<FeatureColumn>
    private let scorer: XGBoostScorer

    public init(warpModelURL: URL, variant: DinoVariant = .small, columns: Set<FeatureColumn> = Set(FeatureColumn.allCases)) throws {
        self.warpModelURL = warpModelURL
        self.variant = variant
        self.columns = columns
        scorer = try TreeModelCache.shared.scorer(warpModelURL)
        warpModelTag = String(try ContentHash.sha256Hex(fileAt: warpModelURL).prefix(12))
    }

    public func extract(_ cg: CGImage) throws -> ExtractedFeatures {
        let nan384 = [Float](repeating: .nan, count: 384)
        let dinoNorm = columns.contains(.dinoNorm) ? try SemanticLens.normalizedEmbedding(cg, variant: variant) : nan384
        let dinoFusion = columns.contains(.dinoFusion) ? try SemanticLens.fusionEmbedding(cg, variant: variant) : nan384
        let cap = columns.contains(.cap) ? CaptureLens.features(cg).asVector : [Float](repeating: .nan, count: CaptureFeatures.count)
        var warp: Float = .nan
        var sharp = [Float](repeating: .nan, count: SharpnessFeatures.count)
        if columns.contains(.warp) || columns.contains(.sharp) {
            let analysis = try WarpLens.analyze(cgImage: cg, parameters: WarpParameters(), scorer: scorer)
            warp = analysis.weightedScore
            let s = analysis.sharpness
            sharp = [s.salientSharp, s.globalSharp, s.sharpRatio]
        }
        let noiseprint: Float = columns.contains(.noiseprint) ? (NoiseprintLens.score(cg) ?? .nan) : .nan
        return ExtractedFeatures(dinoNorm: dinoNorm, dinoFusion: dinoFusion, cap: cap, warp: warp, sharp: sharp, noiseprint: noiseprint,
                                 width: cg.width, height: cg.height)
    }

    public func extract(contentsOf url: URL) throws -> ExtractedFeatures { try extract(try ImageDecoding.cgImage(contentsOf: url)) }
}
