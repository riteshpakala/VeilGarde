//
//  CameraRow.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The camera head's input, the camera member's view of an image: the DINOv2 CLS embedding
//        (what the image depicts) and the nine capture values (whether a sensor made it),
//        384 + 9 = 393 columns. The camera member builds it from the shared signals; the trainer
//        builds it from the store's columns in the same order.
//  PIN:  Column order is [dino_fusion(384), cap(9)], the store's FeatureColumn order and the
//        shipped head's. dino_fusion is the PLAIN preprocessing (short edge 256, centre crop 224).
//

public struct CameraRow: Sendable, Equatable {
    public static let dinoWidth = 384
    /// The store's columns, in the head's order.
    public static let columns: [FeatureColumn] = [.dinoFusion, .cap]
    public static let width = dinoWidth + CaptureFeatures.count

    public var dino: [Float]
    public var capture: CaptureFeatures

    public init(dino: [Float], capture: CaptureFeatures) {
        precondition(dino.count == Self.dinoWidth, "the camera row's embedding has \(Self.dinoWidth) values")
        self.dino = dino
        self.capture = capture
    }

    public var asVector: [Float] { dino + capture.asVector }

    /// The column names, for reports and feature-importance tables.
    public static var names: [String] { (0..<dinoWidth).map { "dino\($0)" } + CaptureFeatures.names.map { "cap_\($0)" } }
}
