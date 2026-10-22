//
//  VeilGardeTraining.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The trainers for every trainable member of the stack: the camera head (a native GBDT that
//        writes XGBoost JSON), the linear heads, the stack combiner, and the backbone imports,
//        declared in a recipe DSL that mirrors the detector's pipeline, whose plan is pure and
//        whose run writes a hashed candidate bundle. Re-exports the Lens and Core.
//  PIN:  Training never imports the detector (VeilGardeInference) or the flywheel: it learns from
//        features and writes artifacts; composing them into a verdict is the detector's job.
//

@_exported import VeilGardeLens
