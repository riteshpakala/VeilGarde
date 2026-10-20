//
//  VeilGardeFlywheel.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The specialist-head regime that grows forever: acquire images and keep only their
//        features, ingest them into the store, train candidate heads (and warm-start the base),
//        stage them for review, gate them with the battery, and promote or roll back the live
//        bundle. Re-exports Training and Inference.
//  PIN:  The warp tile model, the frozen fusion reference, noiseprint and the backbones never move
//        here (FlywheelPolicy.frozen); promote is the only writer of the live bundle.
//

@_exported import VeilGardeInference
@_exported import VeilGardeTraining
