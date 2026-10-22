//
//  Detector.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The detector's one entry point: a decoded image through a pipeline, the shipped one
//        unless told otherwise, into one result.
//  PIN:  The command line, the battery, the census and the goldens all call this; none builds the
//        stack itself.
//

import CoreGraphics

public enum Detector {
    /// The full result for one image.
    public static func detect(cgImage: CGImage, config: InferenceConfig = .shipped, pipeline: Pipeline = .v1) throws -> InferenceResult {
        try pipeline.run(cgImage: cgImage, config: config)
    }
}
