//
//  FusionVector.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The fusion head's input, the camera base expert's view of an image, in one of three
//        layouts: the DINOv2 CLS embedding (what the image depicts) and the nine capture values
//        (whether a sensor made it), 384 + 9 = 393 columns; both DINOv2 readings, the plain CLS and
//        the specialist heads' force-resized one, and the capture values, 777; or those and the
//        warp residual's statistics, 38 more, 815. A head's width names its layout.
//  PIN:  Column order is the layout's FeatureColumn order, the store's and the head's. dino_fusion
//        is the PLAIN preprocessing (short edge 256, centre crop 224); dino_norm is the 360×640
//        force-resize the specialist heads read; residual is VeilWatermark's ResidualStatistics.
//

/// The fusion head's row layouts. The head shipped on 2026-10-21 reads `.dinoCapture`.
public enum FusionLayout: String, Codable, Sendable, CaseIterable {
    case dinoCapture = "dino_fusion,cap"
    case bothReadings = "dino_fusion,dino_norm,cap"
    case bothReadingsResidual = "dino_fusion,dino_norm,cap,residual"

    /// The store's columns, in the head's order.
    public var columns: [FeatureColumn] {
        switch self {
        case .dinoCapture: return [.dinoFusion, .cap]
        case .bothReadings: return [.dinoFusion, .dinoNorm, .cap]
        case .bothReadingsResidual: return [.dinoFusion, .dinoNorm, .cap, .residual]
        }
    }

    public var width: Int { columns.map(\.width).reduce(0, +) }

    /// The layout a head of this width reads; nil for any other width.
    public init?(width: Int) {
        guard let layout = Self.allCases.first(where: { $0.width == width }) else { return nil }
        self = layout
    }

    /// The layout a head of this width reads, or a failure naming the widths there are.
    public static func of(width: Int) throws -> FusionLayout {
        guard let layout = FusionLayout(width: width) else {
            throw VeilGardeFailure.data("a fusion head reads \(width) features; the layouts are \(allCases.map(\.width).map(String.init).joined(separator: " and "))")
        }
        return layout
    }

    /// The column names, for reports and feature-importance tables.
    public var names: [String] {
        columns.flatMap { column -> [String] in
            switch column {
            case .dinoFusion: return (0..<column.width).map { "dino\($0)" }
            case .dinoNorm: return (0..<column.width).map { "dnorm\($0)" }
            case .cap: return CaptureFeatures.names.map { "cap_\($0)" }
            case .residual: return FeatureColumn.residualNames.map { "res_\($0)" }
            }
        }
    }
}

public struct FusionVector: Sendable, Equatable {
    public var dino: [Float]
    /// The force-resized embedding, for the `.bothReadings` layout.
    public var dinoNorm: [Float]?
    public var capture: CaptureFeatures

    public static let dinoWidth = 384
    /// The `.dinoCapture` layout's width.
    public static let count = FusionLayout.dinoCapture.width

    public init(dino: [Float], dinoNorm: [Float]? = nil, capture: CaptureFeatures) {
        precondition(dino.count == Self.dinoWidth, "the fusion vector's embedding has \(Self.dinoWidth) values")
        precondition(dinoNorm.map { $0.count == Self.dinoWidth } ?? true, "the force-resized embedding has \(Self.dinoWidth) values")
        self.dino = dino
        self.dinoNorm = dinoNorm
        self.capture = capture
    }

    public var layout: FusionLayout { dinoNorm == nil ? .dinoCapture : .bothReadings }

    public var asVector: [Float] { dino + (dinoNorm ?? []) + capture.asVector }

    /// The `.dinoCapture` layout's column names.
    public static var names: [String] { FusionLayout.dinoCapture.names }
}
