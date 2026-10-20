//
//  FeatureShard.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: One shard of the store: `<name>.safetensors` holds each column as an F32 [N, width]
//        tensor (NaN where a value is missing) and `<name>_meta.json` holds the N rows, in order.
//  PIN:  The Python feature store's layout (write_shard), so both sides read each other's shards. A
//        VeilGarde shard also carries a safetensors header recording which models produced its
//        columns (format veilgarde-feature-shard-v2); the seed shards have none. Writing refuses to
//        replace an existing shard: the Python write_shard overwrote silently, and a lost shard is lost
//        features whose images no longer exist.
//

import Foundation

public struct FeatureShard: Sendable {
    public static let format = "veilgarde-feature-shard-v2"

    public let name: String
    public var rows: [FeatureRow]
    /// Each column flattened row-major, [count × width].
    public var columns: [FeatureColumn: [Float]]
    public var metadata: [String: String]

    public init(name: String, rows: [FeatureRow], columns: [FeatureColumn: [Float]], metadata: [String: String] = [:]) {
        self.name = name
        self.rows = rows
        self.columns = columns
        self.metadata = metadata
    }

    public var count: Int { rows.count }

    /// Row `index` of `column`.
    public func vector(_ column: FeatureColumn, row index: Int) -> ArraySlice<Float> {
        guard let values = columns[column] else { return [] }
        let w = column.width
        return values[(index * w)..<((index + 1) * w)]
    }

    public static func metaURL(_ directory: URL, _ name: String) -> URL { directory.appendingPathComponent("\(name)_meta.json") }
    public static func tensorsURL(_ directory: URL, _ name: String) -> URL { directory.appendingPathComponent("\(name).safetensors") }

    /// Reads a shard; `columns` nil reads every column present.
    public static func read(_ name: String, in directory: URL, columns wanted: Set<FeatureColumn>? = nil) throws -> FeatureShard {
        let rows: [FeatureRow]
        do { rows = try JSONDecoder().decode([FeatureRow].self, from: Data(contentsOf: metaURL(directory, name))) } catch {
            throw VeilGardeFailure.data("\(name)_meta.json is not a feature-store meta list: \(error)")
        }
        let file = try SafetensorsFile(url: tensorsURL(directory, name))
        var columns: [FeatureColumn: [Float]] = [:]
        for column in FeatureColumn.allCases where wanted?.contains(column) ?? true {
            guard let tensor = file.tensors[column.rawValue] else { continue }
            guard tensor.shape == [rows.count, column.width] || (column.width == 1 && tensor.shape == [rows.count]) else {
                throw VeilGardeFailure.data("\(name).\(column.rawValue) is \(tensor.shape), not [\(rows.count), \(column.width)]")
            }
            columns[column] = try file.float32(column.rawValue)
        }
        return FeatureShard(name: name, rows: rows, columns: columns, metadata: file.metadata)
    }

    /// Writes `<name>.safetensors` and `<name>_meta.json` into `directory`; refuses to overwrite.
    public func write(to directory: URL, replacing: Bool = false) throws {
        let meta = Self.metaURL(directory, name), tensors = Self.tensorsURL(directory, name)
        if !replacing, FileManager.default.fileExists(atPath: meta.path) || FileManager.default.fileExists(atPath: tensors.path) {
            throw VeilGardeFailure.exists("the shard \(name) already exists in \(directory.path)", hint: "name the new shard differently; shards are written once")
        }
        var entries: [SafetensorsWriter.Entry] = []
        for column in FeatureColumn.allCases {
            guard let values = columns[column] else { continue }
            guard values.count == rows.count * column.width else {
                throw VeilGardeFailure.internalError("\(name).\(column.rawValue) holds \(values.count) values for \(rows.count) rows")
            }
            entries.append(.init(column.rawValue, shape: [rows.count, column.width], .float32(values)))
        }
        var header = metadata
        header["format"] = Self.format
        header["rows"] = String(rows.count)
        header["core_version"] = VeilGardeVersion.string
        try SafetensorsWriter.write(entries, metadata: header, to: tensors)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(rows).write(to: meta, options: .atomic)
    }
}
