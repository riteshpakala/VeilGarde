//
//  LinearHead.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The shared primitive of every DINOv2 specialist (screenshot, art, blur, human, art-pair,
//        cgi, preview, semantic tiles): a standardized linear probe on a 384-value embedding,
//        P(AI) = σ(Σ coef · (e − mean) / scale + intercept). A new specialist is a new head file,
//        not new plumbing.
//  PIN:  Arithmetic is Garde's LinearHead.pAI in Float, accumulated in index order, a zero scale
//        read as 1. A head file is read with JSONDecoder into Float, as Garde reads it. HeadFile
//        is what the trainer writes: the same keys, in Double, so Python reads full precision.
//

import Foundation

public struct LinearHead: Sendable, Equatable {
    public let mean: [Float]
    public let scale: [Float]
    public let coef: [Float]
    public let intercept: Float
    public let threshold: Float
    /// The force-resize the head's embedding is taken at (width, height); 360×640 unless stated.
    public let normW: Int
    public let normH: Int

    public init(mean: [Float], scale: [Float], coef: [Float], intercept: Float, threshold: Float = 0.5, normW: Int = 360, normH: Int = 640) {
        self.mean = mean
        self.scale = scale
        self.coef = coef
        self.intercept = intercept
        self.threshold = threshold
        self.normW = normW
        self.normH = normH
    }

    public func pAI(_ embedding: [Float]) -> Float {
        var z = intercept
        let n = min(embedding.count, coef.count)
        for i in 0..<n {
            let s = scale[i] == 0 ? 1 : scale[i]
            z += ((embedding[i] - mean[i]) / s) * coef[i]
        }
        return 1.0 / (1.0 + exp(-z))
    }

    /// Reads a head file (Garde's format, which the trainer also writes).
    public init(data: Data) throws {
        let json: Mirror
        do { json = try JSONDecoder().decode(Mirror.self, from: data) } catch {
            throw VeilGardeFailure.data("not a linear head: \(error)")
        }
        guard json.scaler_mean.count == json.coef.count, json.scaler_scale.count == json.coef.count else {
            throw VeilGardeFailure.data("a linear head's scaler and coef widths differ (\(json.scaler_mean.count), \(json.scaler_scale.count), \(json.coef.count))")
        }
        let size = json.normalize_size?.count == 2 ? json.normalize_size! : [360, 640]
        self.init(mean: json.scaler_mean, scale: json.scaler_scale, coef: json.coef, intercept: json.intercept,
                  threshold: json.threshold ?? 0.5, normW: size[0], normH: size[1])
    }

    public static func load(_ url: URL) throws -> LinearHead { try LinearHead(data: Data(contentsOf: url)) }

    private struct Mirror: Decodable {
        let scaler_mean: [Float]
        let scaler_scale: [Float]
        let coef: [Float]
        let intercept: Float
        let threshold: Float?
        let normalize_size: [Int]?
    }
}

/// A linear head as the trainer writes it: the head schema, numbers in Double.
public struct HeadFile: Codable, Sendable, Equatable {
    public var model: String
    public var backbone: String
    public var embedSource: String
    public var normalizeSize: [Int]?
    public var threshold: Double
    public var fireThreshold: Double?
    public var scalerMean: [Double]
    public var scalerScale: [Double]
    public var coef: [Double]
    public var intercept: Double
    public var note: String?

    public init(model: String, backbone: String = "facebook/dinov2-small", embedSource: String = "swift", normalizeSize: [Int]? = [360, 640],
                threshold: Double = 0.5, fireThreshold: Double? = 0.8, scalerMean: [Double], scalerScale: [Double], coef: [Double],
                intercept: Double, note: String? = nil) {
        self.model = model
        self.backbone = backbone
        self.embedSource = embedSource
        self.normalizeSize = normalizeSize
        self.threshold = threshold
        self.fireThreshold = fireThreshold
        self.scalerMean = scalerMean
        self.scalerScale = scalerScale
        self.coef = coef
        self.intercept = intercept
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case model, backbone, threshold, coef, intercept, note
        case embedSource = "embed_source"
        case normalizeSize = "normalize_size"
        case fireThreshold = "fire_threshold"
        case scalerMean = "scaler_mean"
        case scalerScale = "scaler_scale"
    }

    /// The runtime head this file loads as.
    public func linearHead() throws -> LinearHead { try LinearHead(data: JSONCoding.prettyEncoder().encode(self)) }
}
