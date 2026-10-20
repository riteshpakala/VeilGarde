//
//  TOMLSubset.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The flat TOML subset a training recipe file (recipe.toml) uses: `key = value` lines, one
//        level of `[table]`, strings, integers, floats, booleans and arrays of strings, `#`
//        comments. The reader refuses anything outside the subset rather than guessing.
//  PIN:  Braid's reader, unchanged, so a recipe and a braid.toml read alike.
//

import Foundation

public enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    case strings([String])

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var integer: Int? {
        switch self {
        case .integer(let i): return i
        case .float(let f) where f == f.rounded(): return Int(f)
        default: return nil
        }
    }
    public var float: Double? {
        switch self {
        case .float(let f): return f
        case .integer(let i): return Double(i)
        default: return nil
        }
    }
    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var strings: [String]? { if case .strings(let a) = self { return a } else { return nil } }

    var rendered: String {
        switch self {
        case .string(let s): return TOMLSubset.quote(s)
        case .integer(let i): return String(i)
        case .float(let f): return f == f.rounded() && abs(f) < 1e15 ? String(format: "%.1f", f) : String(f)
        case .bool(let b): return b ? "true" : "false"
        case .strings(let a): return "[" + a.map(TOMLSubset.quote).joined(separator: ", ") + "]"
        }
    }
}

public enum TOMLSubset {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case line(Int, String)

        public var description: String {
            switch self {
            case .line(let n, let why): return "toml line \(n): \(why)"
            }
        }
    }

    /// Tables by name ("" for the top level), keys in order of appearance.
    public typealias Document = [(table: String, entries: [(key: String, value: TOMLValue)])]

    public static func parse(_ text: String) throws -> Document {
        var document: Document = [("", [])]
        var current = 0
        for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = stripComment(String(raw)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), !line.hasPrefix("[[") else { throw Failure.line(n + 1, "only one level of table") }
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                guard isBareKey(name) else { throw Failure.line(n + 1, "table name \(name) is not a bare key") }
                document.append((name, []))
                current = document.count - 1
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { throw Failure.line(n + 1, "expected key = value") }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            guard isBareKey(key) else { throw Failure.line(n + 1, "key \(key) is not a bare key") }
            let value = try parseValue(String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces), line: n + 1)
            document[current].entries.append((key, value))
        }
        return document
    }

    public static func render(_ document: Document) -> String {
        var out = ""
        for (i, table) in document.enumerated() {
            if !table.table.isEmpty {
                if !out.isEmpty { out += "\n" }
                out += "[\(table.table)]\n"
            } else if i > 0 {
                out += "\n"
            }
            for entry in table.entries { out += "\(entry.key) = \(entry.value.rendered)\n" }
        }
        return out
    }

    public static func value(_ document: Document, _ table: String, _ key: String) -> TOMLValue? {
        document.first { $0.table == table }?.entries.first { $0.key == key }?.value
    }

    static func isBareKey(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } }

    static func stripComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        for (i, c) in line.enumerated() {
            if escaped { escaped = false; continue }
            if c == "\\", inString { escaped = true; continue }
            if c == "\"" { inString.toggle() }
            if c == "#", !inString { return String(line.prefix(i)) }
        }
        return line
    }

    static func parseValue(_ text: String, line: Int) throws -> TOMLValue {
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        if text.hasPrefix("\"") {
            guard let s = unquote(text) else { throw Failure.line(line, "unterminated string") }
            return .string(s)
        }
        if text.hasPrefix("[") {
            guard text.hasSuffix("]") else { throw Failure.line(line, "unterminated array") }
            let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .strings([]) }
            var items: [String] = []
            for part in splitTopLevel(inner) {
                guard let s = unquote(part.trimmingCharacters(in: .whitespaces)) else { throw Failure.line(line, "arrays hold strings only") }
                items.append(s)
            }
            return .strings(items)
        }
        if let i = Int(text) { return .integer(i) }
        if let f = Double(text) { return .float(f) }
        throw Failure.line(line, "value \(text) is not in the subset")
    }

    static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        for c in text {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\", inString { current.append(c); escaped = true; continue }
            if c == "\"" { inString.toggle() }
            if c == ",", !inString { parts.append(current); current = ""; continue }
            current.append(c)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }

    static func unquote(_ s: String) -> String? {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return nil }
        var out = ""
        var escaped = false
        for c in s.dropFirst().dropLast() {
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return escaped ? nil : out
    }
}
