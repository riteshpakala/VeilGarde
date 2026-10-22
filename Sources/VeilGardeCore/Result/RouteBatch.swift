//
//  RouteBatch.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The strict JSONL batch manifest `veilgarde batch` reads: one {id, path} object per line,
//        validated whole before any inference starts, so a malformed late row never leaves a
//        partial campaign artifact.
//  PIN:  Exactly the two string fields, ids trimmed, control-free and unique, a BOM and CRLF
//        tolerated. Every image runs the whole stack, so there is nothing to hint.
//

import Foundation

public struct RouteBatchItem: Sendable, Equatable {
    public let id: String
    public let path: String

    public init(id: String, path: String) {
        self.id = id
        self.path = path
    }
}

public enum RouteBatchError: Error, LocalizedError, Equatable {
    case invalidUTF8
    case emptyInput
    case blankLine(Int)
    case invalidJSON(line: Int, detail: String)
    case invalidShape(line: Int)
    case invalidID(line: Int)
    case duplicateID(line: Int, id: String)
    case invalidPath(line: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: return "batch input is not valid UTF-8"
        case .emptyInput: return "batch input contains no items"
        case .blankLine(let line): return "batch line \(line) is blank"
        case .invalidJSON(let line, let detail): return "batch line \(line) is invalid JSON: \(detail)"
        case .invalidShape(let line): return "batch line \(line) must contain exactly string fields {id,path}"
        case .invalidID(let line): return "batch line \(line) has an invalid id (must be non-empty, trimmed, and control-free)"
        case .duplicateID(let line, let id): return "batch line \(line) repeats id \(id)"
        case .invalidPath(let line): return "batch line \(line) has an invalid path"
        }
    }
}

public enum RouteBatch {
    public static func parse(_ data: Data) throws -> [RouteBatchItem] {
        guard var text = String(data: data, encoding: .utf8) else { throw RouteBatchError.invalidUTF8 }
        if text.first == "\u{feff}" { text.removeFirst() }
        var rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if rawLines.last?.isEmpty == true { rawLines.removeLast() }
        guard !rawLines.isEmpty else { throw RouteBatchError.emptyInput }

        let expectedKeys = Set(["id", "path"])
        let whitespace = CharacterSet.whitespacesAndNewlines
        let controls = CharacterSet.controlCharacters
        var seen = Set<String>()
        var items = [RouteBatchItem]()
        items.reserveCapacity(rawLines.count)

        for (offset, rawLine) in rawLines.enumerated() {
            let lineNumber = offset + 1
            var line = String(rawLine)
            if line.last == "\r" { line.removeLast() }
            guard !line.trimmingCharacters(in: whitespace).isEmpty else { throw RouteBatchError.blankLine(lineNumber) }
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            } catch {
                throw RouteBatchError.invalidJSON(line: lineNumber, detail: error.localizedDescription)
            }
            guard let dictionary = object as? [String: Any], Set(dictionary.keys) == expectedKeys,
                  let id = dictionary["id"] as? String, let path = dictionary["path"] as? String else {
                throw RouteBatchError.invalidShape(line: lineNumber)
            }
            guard !id.isEmpty, id == id.trimmingCharacters(in: whitespace), id.unicodeScalars.allSatisfy({ !controls.contains($0) }) else {
                throw RouteBatchError.invalidID(line: lineNumber)
            }
            guard seen.insert(id).inserted else { throw RouteBatchError.duplicateID(line: lineNumber, id: id) }
            guard !path.isEmpty, path == path.trimmingCharacters(in: whitespace), path.unicodeScalars.allSatisfy({ !controls.contains($0) }) else {
                throw RouteBatchError.invalidPath(line: lineNumber)
            }
            items.append(RouteBatchItem(id: id, path: path))
        }
        return items
    }
}
