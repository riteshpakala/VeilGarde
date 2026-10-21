//
//  FusionVector.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The fusion head's input, the camera base expert's view of an image: the DINOv2 CLS
//        embedding (what the image depicts) and the nine capture values (whether a sensor made
//        it). 384 + 9 = 393 columns.
//  PIN:  Column order [dino(384), capture(9)] is the fusion head's and the store's
//        FeatureColumn.fusion. The DINOv2 embedding here is the PLAIN preprocessing (short edge
//        256, centre crop 224), not the 360×640 force-resize the specialist heads read.
//

public struct FusionVector: Sendable, Equatable {
    public var dino: [Float]
    public var capture: CaptureFeatures

    public static let dinoWidth = 384
    public static let count = dinoWidth + CaptureFeatures.count

    public init(dino: [Float], capture: CaptureFeatures) {
        precondition(dino.count == Self.dinoWidth, "the fusion vector's embedding has \(Self.dinoWidth) values")
        self.dino = dino
        self.capture = capture
    }

    public var asVector: [Float] { dino + capture.asVector }

    /// The column names, for reports and feature-importance tables.
    public static var names: [String] {
        (0..<dinoWidth).map { "dino\($0)" } + CaptureFeatures.names.map { "cap_\($0)" }
    }
}
