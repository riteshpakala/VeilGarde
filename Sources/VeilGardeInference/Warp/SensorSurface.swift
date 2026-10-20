//
//  SensorSurface.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The public camera-sensor map: P(generated) per 32-px tile from the sensor model. When the
//        sensor model's bytes equal the base's and the base grid is the 32-px tile grid, it IS the
//        base grid; otherwise the Lens scores it in a second pass on its own lane.
//  PIN:  Garde's MajoritySensorSurface. The second pass is intentional: the validated base grid stays
//        on its own model and geometry and keeps owning the weighted and fusion semantics.
//

import CoreGraphics

struct SensorSurface {
    let patchGrid: [[Float]]
    let rows: Int
    let cols: Int
    let patchSize: Int
    let imageWidth: Int
    let imageHeight: Int

    /// The dedicated pass, on the raw 32-px lane whatever the base's presentation patch size.
    static func score(cgImage: CGImage, warp: WarpParameters, scorer: TileScorer) throws -> SensorSurface {
        let lane = try WarpLens.sensorLane(cgImage: cgImage, parameters: warp, scorer: scorer)
        return SensorSurface(patchGrid: lane.grid, rows: lane.rows, cols: lane.cols, patchSize: WarpConstants.tileSize,
                             imageWidth: lane.geometry.imageWidth, imageHeight: lane.geometry.imageHeight)
    }
}
