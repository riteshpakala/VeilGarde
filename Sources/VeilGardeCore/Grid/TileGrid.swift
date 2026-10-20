//
//  TileGrid.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A rows × cols grid of values in row-major order: per-tile P(generated), texture, weight,
//        fragility. The one shape the lens hands to the verdict and the watermark reads.
//

public struct TileGrid<Value: Sendable & Equatable>: Sendable, Equatable {
    public let rows: Int
    public let cols: Int
    public private(set) var values: [Value]

    public init(rows: Int, cols: Int, values: [Value]) {
        precondition(values.count == rows * cols, "a \(rows)×\(cols) grid holds \(rows * cols) values, not \(values.count)")
        self.rows = rows
        self.cols = cols
        self.values = values
    }

    public init(rows: Int, cols: Int, repeating value: Value) {
        self.init(rows: rows, cols: cols, values: Array(repeating: value, count: rows * cols))
    }

    /// The grid a `[[Value]]` row list describes (every row the same length).
    public init(_ rowsArray: [[Value]]) {
        let cols = rowsArray.first?.count ?? 0
        precondition(rowsArray.allSatisfy { $0.count == cols }, "every row of a grid has the same length")
        self.init(rows: rowsArray.count, cols: cols, values: rowsArray.flatMap { $0 })
    }

    public subscript(row: Int, col: Int) -> Value {
        get { values[row * cols + col] }
        set { values[row * cols + col] = newValue }
    }

    public func map<T: Sendable & Equatable>(_ transform: (Value) -> T) -> TileGrid<T> {
        TileGrid<T>(rows: rows, cols: cols, values: values.map(transform))
    }

    /// The grid as rows, the shape the result JSON writes.
    public var rowsArray: [[Value]] {
        (0..<rows).map { r in Array(values[(r * cols)..<((r + 1) * cols)]) }
    }
}
