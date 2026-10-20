//
//  FusionVector.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The fusion head's input, the camera base expert's view of an image: the warp lens's
//        weighted score, the DINOv2 CLS embedding (what the image depicts), the nine capture
//        values (whether a sensor made it) and the three sharpness values (whether the subject is
//        in focus). 1 + 384 + 9 + 3 = 397 columns.
//  PIN:  Column order [warp.weighted, dino(384), capture(9), sharp(3)] is the fusion head's
//        (Garde fuseVerdict, the store's fusion_matrix). The DINOv2 embedding here is the
//        PLAIN preprocessing (short edge 256, centre crop 224), not the 360×640 force-resize the
//        specialist heads read.
//

public struct FusionVector: Sendable, Equatable {
    public var warp: Float
    public var dino: [Float]
    public var capture: CaptureFeatures
    public var sharpness: SharpnessFeatures

    public static let dinoWidth = 384
    public static let count = 1 + dinoWidth + CaptureFeatures.count + SharpnessFeatures.count

    public init(warp: Float, dino: [Float], capture: CaptureFeatures, sharpness: SharpnessFeatures) {
        precondition(dino.count == Self.dinoWidth, "the fusion vector's embedding has \(Self.dinoWidth) values")
        self.warp = warp
        self.dino = dino
        self.capture = capture
        self.sharpness = sharpness
    }

    public var asVector: [Float] { [warp] + dino + capture.asVector + sharpness.asVector }

    /// The column names, for reports and feature-importance tables.
    public static var names: [String] {
        ["warp_weighted"] + (0..<dinoWidth).map { "dino\($0)" } + CaptureFeatures.names.map { "cap_\($0)" } + SharpnessFeatures.names
    }
}
