//
//  TileScorer.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The seam between the warp features and a verdict: anything that maps a batch of feature
//        rows to P(generated) per row. The lens scores tiles through Frigate's XGBoostTreeModel;
//        training scores held-out rows through GBDTModel; both conform.
//

public protocol TileScorer: Sendable {
    /// Feature-vector width the scorer reads (0 if unknown). The extractor computes the 21-value
    /// directional signature only when this exceeds 19.
    var featureCount: Int { get }
    func scoreBatch(_ rows: [[Float]]) -> [Float]
}
