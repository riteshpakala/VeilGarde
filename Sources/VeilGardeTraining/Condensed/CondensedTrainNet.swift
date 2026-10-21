//
//  CondensedTrainNet.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: One small network over everything the stack reads, in the form it trains in. A shared
//        per-tile network reads each tile's core warp features, texture and place and gives an
//        embedding and a tile logit; the tiles are pooled by their mean embedding, the mean tile
//        probability (a soft tile vote) and the texture-weighted mean probability. Beside them, a
//        provenance branch reads the capture values and the noiseprint, and a semantic branch reads
//        DINOv2's embedding. A head reads the concatenation and gives one logit. Branches an arm
//        leaves out are not read.
//  PIN:  Pooling is by means, never softmax attention: the research found an attention-pooled
//        co-registered head fired on single regions and closed at parity with the flat fusion
//        (2026-07-20, quoted). GELU throughout, dropout on the semantic branch only. The loss adds
//        the tile logits' cross-entropy against the image's label, weighted, so the tile branch
//        stays a tile detector as the warp model is.
//

import Foundation
import MLX
import MLXNN

/// Which branches a condensed model reads, and their widths.
public struct CondensedShape: Codable, Sendable, Equatable {
    /// The tile branch's channels (core features, texture, row, column); 0 without tiles.
    public var tileChannels: Int
    /// The aggregate branch's width (four per core feature); 0 without it.
    public var aggregateWidth: Int
    public var provenance: Bool
    public var semantic: Bool
    public var hidden = 32
    public var provenanceHidden = 16
    public var semanticHidden = 64
    public var headHidden = 64
    public var dropout = 0.2

    var headInput: Int {
        (tileChannels > 0 ? hidden + 2 : 0) + (aggregateWidth > 0 ? hidden : 0) + (provenance ? provenanceHidden : 0) + (semantic ? semanticHidden : 0)
    }
}

final class CondensedTrainNet: Module {
    let shape: CondensedShape
    @ModuleInfo(key: "tile_in") var tileIn: Linear
    @ModuleInfo(key: "tile_mid") var tileMid: Linear
    @ModuleInfo(key: "tile_logit") var tileLogit: Linear
    @ModuleInfo(key: "aggregate_in") var aggregateIn: Linear
    @ModuleInfo(key: "provenance_in") var provenanceIn: Linear
    @ModuleInfo(key: "semantic_in") var semanticIn: Linear
    @ModuleInfo(key: "semantic_drop") var semanticDrop: Dropout
    @ModuleInfo(key: "head_mid") var headMid: Linear
    @ModuleInfo(key: "head_out") var headOut: Linear

    init(_ shape: CondensedShape) {
        self.shape = shape
        let h = shape.hidden
        _tileIn.wrappedValue = Linear(max(1, shape.tileChannels), h)
        _tileMid.wrappedValue = Linear(h, h)
        _tileLogit.wrappedValue = Linear(h, 1)
        _aggregateIn.wrappedValue = Linear(max(1, shape.aggregateWidth), h)
        _provenanceIn.wrappedValue = Linear(CondensedSet.provenanceWidth, shape.provenanceHidden)
        _semanticIn.wrappedValue = Linear(CondensedSet.semanticWidth, shape.semanticHidden)
        _semanticDrop.wrappedValue = Dropout(p: Float(shape.dropout))
        _headMid.wrappedValue = Linear(max(1, shape.headInput), shape.headHidden)
        _headOut.wrappedValue = Linear(shape.headHidden, 1)
        super.init()
    }

    /// arrays: tiles [B,T,C], mask [B,T,1], weights [B,T,1], aggregates [B,A], provenance [B,11], semantic [B,384].
    /// Returns the image logits [B] and the tile logits [B,T] (nil without tiles).
    func forward(_ a: [MLXArray]) -> (MLXArray, MLXArray?) {
        var parts: [MLXArray] = []
        var tileLogits: MLXArray? = nil
        if shape.tileChannels > 0 {
            let mask = a[1], weights = a[2] * a[1]
            let h = gelu(tileMid(gelu(tileIn(a[0]))))
            let count = mask.sum(axes: [1]) + 1e-6
            let l = tileLogit(h)
            let p = sigmoid(l)
            parts.append((h * mask).sum(axes: [1]) / count)
            parts.append((p * mask).sum(axes: [1]) / count)
            parts.append((p * weights).sum(axes: [1]) / (weights.sum(axes: [1]) + 1e-6))
            tileLogits = l.squeezed(axis: 2)
        }
        if shape.aggregateWidth > 0 { parts.append(gelu(aggregateIn(a[3]))) }
        if shape.provenance { parts.append(gelu(provenanceIn(a[4]))) }
        if shape.semantic { parts.append(semanticDrop(gelu(semanticIn(a[5])))) }
        let z = concatenated(parts, axis: 1)
        return (headOut(gelu(headMid(z))).squeezed(axis: 1), tileLogits)
    }

    /// The training loss: the image's cross-entropy plus `tileWeight` × the tiles' (masked), against the image label a[6].
    func loss(_ a: [MLXArray], tileWeight: Float) -> MLXArray {
        let (logit, tiles) = forward(a)
        let y = a[6]
        var total = binaryCrossEntropy(logits: logit, targets: y, reduction: .mean)
        if let tiles, tileWeight > 0 {
            let mask = a[1].squeezed(axis: 2)
            let target = y.reshaped([-1, 1]) * MLXArray.ones([1, tiles.dim(1)])
            let perTile = binaryCrossEntropy(logits: tiles, targets: target, reduction: .none) * mask
            total = total + tileWeight * perTile.sum() / (mask.sum() + 1e-6)
        }
        return total
    }

    /// The parameters of the branches this shape reads, by name.
    func activeParameters() -> [String: MLXArray] {
        var keep: [String] = ["head_mid", "head_out"]
        if shape.tileChannels > 0 { keep += ["tile_in", "tile_mid", "tile_logit"] }
        if shape.aggregateWidth > 0 { keep.append("aggregate_in") }
        if shape.provenance { keep.append("provenance_in") }
        if shape.semantic { keep.append("semantic_in") }
        return Dictionary(uniqueKeysWithValues: parameters().flattened().filter { name, _ in keep.contains { name.hasPrefix($0 + ".") } })
    }
}
