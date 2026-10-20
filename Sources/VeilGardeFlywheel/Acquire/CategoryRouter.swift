//
//  CategoryRouter.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What an acquired image depicts, from CLIP: its category among five prompts (a
//        person, a sharp scene, a blur, a render, art) and its NSFW margin (the best NSFW prompt's
//        logit minus the best safe prompt's). The category decides which head a generated image
//        trains; the margin keeps NSFW rows out of the base corpus. It never touches a label.
//  PIN:  atlas_route_gen.py: argmax over 100·cos(image, prompt) for the five category prompts,
//        "photo" (a sharp scene) folded into art, applied to generated images only.
//        atlas_nsfw_scan.py with flywheel_nsfw_list.py's aggressive bar: flagged when the margin
//        exceeds 0. The prompt matrix is clip_prompts_v1.safetensors (13 × 512, written once from
//        HF's CLIP text tower).
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens

public struct RouteResult: Codable, Sendable, Equatable {
    /// 100·cos to each of the five category prompts, in CategoryRouter.categories' order.
    public var scores: [Float]
    /// The best category prompt, before folding.
    public var top: String
    /// The category a generated image is filed under ("photo" folds into "art").
    public var category: String
    public var nsfwMargin: Float
    public var nsfw: Bool { nsfwMargin > 0 }
}

public final class CategoryRouter {
    public static let categories = ["human", "photo", "blur", "cgi", "art"]
    public let prompts: [Float]
    public let scale: Float
    public let nsfwRange: Range<Int>
    public let safeRange: Range<Int>

    public init(promptsURL: URL? = nil) throws {
        let file = try SafetensorsFile(url: promptsURL ?? FlywheelResources.url("clip_prompts_v1.safetensors"))
        prompts = try file.float32("prompts")
        scale = Float(file.metadata["logit_scale"].flatMap(Double.init) ?? 100)
        guard prompts.count == 13 * CLIPVision.embeddingWidth else { throw VeilGardeFailure.data("the prompt matrix holds \(prompts.count) values, not 13 × 512") }
        nsfwRange = 5..<10
        safeRange = 10..<13
    }

    func logit(_ e: [Float], _ k: Int) -> Float {
        let w = CLIPVision.embeddingWidth
        var s: Float = 0
        for j in 0..<w { s += e[j] * prompts[k * w + j] }
        return scale * s
    }

    public func route(embedding e: [Float]) -> RouteResult {
        let scores = (0..<5).map { logit(e, $0) }
        let top = Self.categories[scores.firstIndex(of: scores.max()!)!]
        let category = ["human": "human", "blur": "blur", "cgi": "cgi"][top] ?? "art"
        let nsfw = nsfwRange.map { logit(e, $0) }.max()! - safeRange.map { logit(e, $0) }.max()!
        return RouteResult(scores: scores, top: top, category: category, nsfwMargin: nsfw)
    }

    public func route(_ cg: CGImage) throws -> RouteResult { route(embedding: try CLIPLens.embedding(cg)) }
}
