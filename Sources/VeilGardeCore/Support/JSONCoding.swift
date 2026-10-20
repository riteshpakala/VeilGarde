//
//  JSONCoding.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The one JSON encoder and decoder VeilGarde writes manifests, recipes, metrics, run logs
//        and staged reviews with.
//  PIN:  Sorted keys and ISO-8601 dates, so the same value always encodes to the same bytes and
//        a manifest's hash means something. Non-finite floats encode as strings so a log line
//        never fails to write. The detector's result JSON (schema v2) is NOT written here: it
//        keeps Garde's JSONSerialization bytes (Result/ResultJSON.swift). Ported from Braid.
//

import Foundation

public enum JSONCoding {
    /// Pretty, sorted, stable. For files people read (manifests, recipes, reports).
    public static func prettyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    /// Compact, sorted, stable. For JSONL rows.
    public static func lineEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try prettyEncoder().encode(value).write(to: url, options: .atomic)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder().decode(type, from: Data(contentsOf: url))
    }

    /// Python's json module writes the bare literals `Infinity`, `-Infinity` and `NaN`, which are
    /// not JSON; Python metrics files and Hugging Face configs carry them. This turns them into the
    /// strings the decoder reads as non-finite floats, outside quoted strings only.
    public static func standardized(_ text: String) -> String {
        let literals = [("-Infinity", "\"-inf\""), ("Infinity", "\"inf\""), ("NaN", "\"nan\"")]
        var out = ""
        var inString = false
        var escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                i = text.index(after: i)
                continue
            }
            if c == "\"" {
                inString = true
                out.append(c)
                i = text.index(after: i)
                continue
            }
            if let (literal, replacement) = literals.first(where: { text[i...].hasPrefix($0.0) }) {
                out += replacement
                i = text.index(i, offsetBy: literal.count)
                continue
            }
            out.append(c)
            i = text.index(after: i)
        }
        return out
    }

    /// Reads JSON that may carry Python's non-standard float literals.
    public static func readStandardized<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder().decode(type, from: Data(standardized(String(contentsOf: url, encoding: .utf8)).utf8))
    }

    /// One compact line, no trailing newline.
    public static func line<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try lineEncoder().encode(value), as: UTF8.self)
    }

    /// Every non-empty line of a JSONL file, decoded.
    public static func readLines<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = decoder()
        return try text.split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }.map { try decoder.decode(type, from: Data($0.utf8)) }
    }
}

/// An append-only JSONL file. One encodable value per line.
public final class JSONLWriter: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle
    private let encoder = JSONCoding.lineEncoder()
    private let lock = NSLock()

    public init(url: URL, truncate: Bool = false) throws {
        self.url = url
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if truncate || !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    public func append<T: Encodable>(_ value: T) throws {
        var data = try encoder.encode(value)
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: data)
    }

    /// Writes an already encoded line.
    public func appendRaw(_ line: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.synchronize()
        try? handle.close()
    }
}
