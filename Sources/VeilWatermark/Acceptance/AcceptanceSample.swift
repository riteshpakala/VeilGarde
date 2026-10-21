//
//  AcceptanceSample.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The images the acceptance runs on: a labeled dataset (final_mixed's folder with its
//        manifest.csv, or a dataset.jsonl of {path, label}) and a seeded sample of at most n of
//        each label, in the dataset's order.
//  PIN:  The sample is the one every acceptance has drawn since 2026-10-19: per label, the rows of
//        that label in manifest order, SplitMix64(seed ^ (label + 1)).permutation(count), the first
//        n kept, then every kept row in manifest order. final_mixed's rows are its CSV's, in file
//        order, under real/ or generated/ by class. Change nothing here without re-running the
//        acceptance: a different sample is a different measurement.
//

import Foundation
import VeilGardeCore

public enum AcceptanceSample {
    /// One labeled image of a dataset: its file and 1 generated, 0 real.
    public struct Item: Sendable, Equatable {
        public let url: URL
        public let label: Int
    }

    /// The dataset's labeled images in its order: a folder with final_mixed's manifest.csv, or a
    /// dataset.jsonl whose relative paths resolve against its folder.
    public static func dataset(_ url: URL) throws -> [Item] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw VeilGardeFailure.missing("no dataset at \(url.path)") }
        return isDirectory.boolValue ? try finalMixed(url) : try jsonl(url)
    }

    /// At most `perLabel` images of each label, seeded, in the dataset's order.
    public static func sample(_ items: [Item], perLabel: Int, seed: UInt64) -> [Item] {
        var keep = Set<Int>()
        for label in [0, 1] {
            let indices = items.indices.filter { items[$0].label == label }
            var rng = SplitMix64(seed: seed ^ UInt64(label + 1))
            for k in rng.permutation(indices.count).prefix(perLabel) { keep.insert(indices[k]) }
        }
        return items.indices.filter(keep.contains).map { items[$0] }
    }

    struct Row: Decodable { let path: String; let label: Int }

    static func jsonl(_ url: URL) throws -> [Item] {
        let root = url.deletingLastPathComponent().standardizedFileURL
        return try JSONCoding.readLines(Row.self, from: url).map {
            Item(url: $0.path.hasPrefix("/") ? URL(fileURLWithPath: $0.path) : root.appendingPathComponent($0.path), label: $0.label)
        }
    }

    /// final_mixed's manifest.csv (dest_name, class, …): images under real/ and generated/.
    static func finalMixed(_ dataset: URL) throws -> [Item] {
        let csv = dataset.appendingPathComponent("manifest.csv")
        guard let text = try? String(contentsOf: csv, encoding: .utf8) else { throw VeilGardeFailure.missing("no manifest.csv in \(dataset.path)") }
        let table = CSV.parse(text)
        guard let header = table.first else { throw VeilGardeFailure.data("\(csv.path) is empty") }
        guard let name = header.firstIndex(of: "dest_name"), let kind = header.firstIndex(of: "class") else {
            throw VeilGardeFailure.data("\(csv.path) has no dest_name or class column")
        }
        let root = dataset.standardizedFileURL
        var items: [Item] = []
        for (n, row) in table.dropFirst().enumerated() where row.count == header.count {
            let label: Int
            switch row[kind] {
            case "generated": label = 1
            case "real": label = 0
            default: throw VeilGardeFailure.data("\(csv.path) row \(n + 2): class \(row[kind]) is neither real nor generated")
            }
            items.append(Item(url: root.appendingPathComponent((label == 1 ? "generated/" : "real/") + row[name]), label: label))
        }
        return items
    }
}

/// RFC 4180 CSV: commas, double-quoted fields with "" escapes, CRLF or LF rows.
enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let c = next() {
            if quoted {
                if c == "\"" {
                    if let d = next() {
                        if d == "\"" { field.unicodeScalars.append("\"") } else { quoted = false; pending = d }
                    } else { quoted = false }
                } else { field.unicodeScalars.append(c) }
                continue
            }
            switch c {
            case "\"": quoted = true
            case ",": row.append(field); field = ""
            case "\r": continue
            case "\n": row.append(field); rows.append(row); row = []; field = ""
            default: field.unicodeScalars.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
