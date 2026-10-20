//
//  SharpnessFeatures.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Saliency-weighted sharpness, the fusion head's last three columns: how sharp the subject
//        region is (texture weighted by the verdict's weight map), how sharp the whole frame is,
//        and their ratio. They let the fusion discount the warp signal when the subject is blurry
//        (reels, bokeh, screenshots) rather than synthetic.
//  PIN:  salient = Σ texture·weight, global = mean texture, ratio = salient / (global + 1e-6), with
//        texture the mean |Sobel| over cv2's uint8 gray (Garde's runInferenceFast, v1.9.4).
//

public struct SharpnessFeatures: Sendable, Equatable, Codable {
    public let salientSharp: Float
    public let globalSharp: Float
    public let sharpRatio: Float

    public init(salientSharp: Float, globalSharp: Float, sharpRatio: Float) {
        self.salientSharp = salientSharp
        self.globalSharp = globalSharp
        self.sharpRatio = sharpRatio
    }

    public static let count = 3
    public static let names = ["salient_sharp", "global_sharp", "sharp_ratio"]
    public var asVector: [Float] { [salientSharp, globalSharp, sharpRatio] }

    /// The three values from a patch grid's texture and the verdict's weight map.
    public static func measure(texWeights: [[Float]], weightMap: [[Float]]) -> SharpnessFeatures {
        let rows = texWeights.count, cols = texWeights.first?.count ?? 0
        var salient: Float = 0, global: Float = 0
        for i in 0..<rows { for j in 0..<cols { salient += texWeights[i][j] * weightMap[i][j]; global += texWeights[i][j] } }
        global /= Float(max(1, rows * cols))
        return SharpnessFeatures(salientSharp: salient, globalSharp: global, sharpRatio: salient / (global + 1e-6))
    }
}
