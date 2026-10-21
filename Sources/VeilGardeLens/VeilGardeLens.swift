//
//  VeilGardeLens.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The extractors: everything that turns an image's pixels into the numbers the models read,
//        in the order a pixel travels (Image, Warp, Capture, Semantic, Scoring). Re-exports
//        VeilGardeCore, so a layer above imports the Lens alone.
//  PIN:  Every MLX symbol here comes from Frigate (MLX, MLXNN, MLXFFT, MLXAccelerate) and the tree
//        evaluator is Frigate's XGBoostTreeModel; nothing Frigate provides is re-implemented.
//

@_exported import VeilGardeCore
