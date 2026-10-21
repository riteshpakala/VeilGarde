//
//  FeatureShard.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: One shard of the store: `<name>.safetensors` holds each column as an F32 [N, width]
//        tensor (NaN where a value is missing) and `<name>_meta.json` holds the N rows, in order.
//        A column measured after a shard was written lives beside it in a side file,
//        `columns/<column>/<name>.safetensors`, bound to the shard's rows by their ids' SHA-256.
//  PIN:  The Python feature store's layout (write_shard), so both sides read each other's shards. A
//        VeilGarde shard also carries a safetensors header recording which models produced its
//        columns (format veilgarde-feature-shard-v2); the seed shards have none. Writing refuses to
//        replace an existing shard: the Python write_shard overwrote silently, and a lost shard is lost
//        features whose images no longer exist. A side file whose ids hash differs is refused, never
//        read out of line.
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
    public static func sideURL(_ directory: URL, _ column: FeatureColumn, _ name: String) -> URL {
        directory.appendingPathComponent("columns/\(column.rawValue)/\(name).safetensors")
    }

    /// The SHA-256 of a shard's row ids, one a line, in order: what binds a side file to its shard.
    public static func idsSHA256(_ rows: [FeatureRow]) -> String { ContentHash.sha256Hex(Data(rows.map(\.id).joined(separator: "\n").utf8)) }

    /// Reads a shard; `columns` nil reads every column present.
    public static func read(_ name: String, in directory: URL, columns wanted: Set<FeatureColumn>? = nil) throws -> FeatureShard {
        let rows: [FeatureRow]
        do { rows = try JSONDecoder().decode([FeatureRow].self, from: Data(contentsOf: metaURL(directory, name))) } catch {
            throw VeilGardeFailure.data("\(name)_meta.json is not a feature-store meta list: \(error)")
        }
        let file = try SafetensorsFile(url: tensorsURL(directory, name))
        var columns: [FeatureColumn: [Float]] = [:]
        for column in FeatureColumn.allCases where wanted?.contains(column) ?? true {
            guard let tensor = file.tensors[column.rawValue] else {
                if let side = try readSide(column, name: name, rows: rows, in: directory) { columns[column] = side }
                continue
            }
            guard tensor.shape == [rows.count, column.width] || (column.width == 1 && tensor.shape == [rows.count]) else {
                throw VeilGardeFailure.data("\(name).\(column.rawValue) is \(tensor.shape), not [\(rows.count), \(column.width)]")
            }
            columns[column] = try file.float32(column.rawValue)
        }
        return FeatureShard(name: name, rows: rows, columns: columns, metadata: file.metadata)
    }

    /// A column's side file for a shard, when there is one; refused when it is not this shard's rows.
    static func readSide(_ column: FeatureColumn, name: String, rows: [FeatureRow], in directory: URL) throws -> [Float]? {
        let url = sideURL(directory, column, name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file = try SafetensorsFile(url: url)
        guard file.metadata["ids_sha256"] == idsSHA256(rows), file.tensors[column.rawValue]?.shape == [rows.count, column.width] else {
            throw VeilGardeFailure.data("columns/\(column.rawValue)/\(name).safetensors is not bound to \(name)'s \(rows.count) rows")
        }
        return try file.float32(column.rawValue)
    }

    /// Writes one column's side file for an existing shard, NaN rows where a value is missing; refuses
    /// to overwrite unless `replacing`.
    public static func writeSide(_ column: FeatureColumn, values: [Float], for name: String, in directory: URL,
                                 metadata: [String: String] = [:], replacing: Bool = false) throws {
        let rows = try JSONDecoder().decode([FeatureRow].self, from: Data(contentsOf: metaURL(directory, name)))
        guard values.count == rows.count * column.width else {
            throw VeilGardeFailure.internalError("\(name).\(column.rawValue) side file holds \(values.count) values for \(rows.count) rows")
        }
        let url = sideURL(directory, column, name)
        if !replacing, FileManager.default.fileExists(atPath: url.path) {
            throw VeilGardeFailure.exists("\(url.path) already exists", hint: "pass --replace to measure the column again")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var header = metadata
        header["format"] = Self.format
        header["rows"] = String(rows.count)
        header["ids_sha256"] = idsSHA256(rows)
        header["core_version"] = VeilGardeVersion.string
        try SafetensorsWriter.write([.init(column.rawValue, shape: [rows.count, column.width], .float32(values))], metadata: header, to: url)
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
