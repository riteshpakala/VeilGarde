//
//  PatchInfo.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: One cell of the sensor map: its place on the grid and in the image, its P(generated),
//        and the share of the frozen base verdict's weight it carries.
//  PIN:  `weight` is the literal contribution of the overlapping base patch to the weighted
//        verdict. A truncated sensor grid can expose only part of that base map, so visible
//        weights may sum below one, by design.
//

public struct PatchInfo: Sendable, Equatable {
    public let row: Int
    public let col: Int
    public let pGenerated: Float
    public let weight: Float
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public var verdict: String { pGenerated > 0.5 ? "generated" : "real" }

    public init(row: Int, col: Int, pGenerated: Float, weight: Float, x: Int, y: Int, width: Int, height: Int) {
        self.row = row
        self.col = col
        self.pGenerated = pGenerated
        self.weight = weight
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
