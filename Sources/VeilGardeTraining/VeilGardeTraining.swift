//
//  VeilGardeTraining.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The trainers for every model VeilGarde ships: the fusion head (a native GBDT that writes
//        XGBoost JSON), the DINOv2 heads, the stack combiner, and the backbone imports, driven by a
//        recipe DSL whose plan is pure and whose build writes a hashed candidate bundle. Re-exports
//        the Lens and Core.
//  PIN:  Training never imports the detector (VeilGardeInference) or the flywheel: it learns from
//        features and writes artifacts; composing them into a verdict is the detector's job.
//

@_exported import VeilGardeLens
