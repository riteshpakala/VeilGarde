//
//  ImageManifest.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The labeled images a model is trained on, one JSON line each (dataset.jsonl): where the
//        image is, its label (1 generated, 0 real), the stem that groups its variants, its pool
//        and tag, and the partition it belongs to. final_mixed's manifest.csv converts into one.
//  PIN:  The partition is StableSplit over "split:v1:" + stem, 70/15/15, unless a row names its
//        own: stem-disjoint (a clean image and its screenshot share a stem and a partition) and
//        auditable from the stem alone. The manifest's SHA-256 is over its canonical JSONL bytes
//        (sorted keys, one row per line), so a tile cache can say which manifest it was cut from.
//

import Foundation
import VeilGardeCore

public struct ImageRecord: Codable, Sendable, Equatable {
    public var path: String
    public var label: Int
    public var stem: String
    public var pool: String?
    public var tag: String?
    public var split: Partition?
    public var sha256: String?

    public init(path: String, label: Int, stem: String, pool: String? = nil, tag: String? = nil, split: Partition? = nil, sha256: String? = nil) {
        self.path = path
        self.label = label
        self.stem = stem
        self.pool = pool
        self.tag = tag
        self.split = split
        self.sha256 = sha256
    }

    public var isGenerated: Bool { label == 1 }
}

public struct ImageManifest: Sendable, Equatable {
    public static let splitSalt = "split:v1"

    public var records: [ImageRecord]
    /// The directory a relative `path` resolves against.
    public var root: URL

    public init(records: [ImageRecord], root: URL) {
        self.records = records
        self.root = root.standardizedFileURL
    }

    public var count: Int { records.count }

    public func url(_ record: ImageRecord) -> URL {
        record.path.hasPrefix("/") ? URL(fileURLWithPath: record.path) : root.appendingPathComponent(record.path)
    }

    /// Every record given a partition: its own, else StableSplit's over the stem.
    public func withSplits(train: Double = 0.70, val: Double = 0.15) -> ImageManifest {
        var out = self
        for i in out.records.indices where out.records[i].split == nil {
            out.records[i].split = StableSplit.partition(out.records[i].stem, salt: Self.splitSalt, train: train, val: val)
        }
        return out
    }

    public func records(in partition: Partition) -> [ImageRecord] { records.filter { $0.split == partition } }

    /// A seeded sample of at most `perLabel` images of each label, in manifest order.
    public func sample(perLabel: Int, seed: UInt64) -> ImageManifest {
        var keep = Set<Int>()
        for label in [0, 1] {
            let indices = records.indices.filter { records[$0].label == label }
            var rng = SplitMix64(seed: seed ^ UInt64(label + 1))
            for k in rng.permutation(indices.count).prefix(perLabel) { keep.insert(indices[k]) }
        }
        return ImageManifest(records: records.indices.filter(keep.contains).map { records[$0] }, root: root)
    }

    // MARK: Files

    public static func load(_ url: URL) throws -> ImageManifest {
        let records = try JSONCoding.readLines(ImageRecord.self, from: url)
        return ImageManifest(records: records, root: url.deletingLastPathComponent())
    }

    public func canonicalBytes() throws -> Data {
        var out = Data()
        for record in records { out.append(Data(try JSONCoding.line(record).utf8)); out.append(0x0A) }
        return out
    }

    public var sha256: String { ContentHash.sha256Hex((try? canonicalBytes()) ?? Data()) }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try canonicalBytes().write(to: url, options: .atomic)
    }

    // MARK: final_mixed

    /// final_mixed's manifest.csv (dest_name, class, source_pool, tag, scored_verdict, src_path):
    /// images under real/ and generated/, the stem the file name without its extension.
    public static func finalMixed(_ dataset: URL) throws -> ImageManifest {
        let csv = dataset.appendingPathComponent("manifest.csv")
        guard let text = try? String(contentsOf: csv, encoding: .utf8) else { throw VeilGardeFailure.missing("no manifest.csv in \(dataset.path)") }
        let table = CSV.parse(text)
        guard let header = table.first else { throw VeilGardeFailure.data("\(csv.path) is empty") }
        func column(_ name: String) throws -> Int {
            guard let i = header.firstIndex(of: name) else { throw VeilGardeFailure.data("\(csv.path) has no \(name) column") }
            return i
        }
        let name = try column("dest_name"), kind = try column("class"), pool = try column("source_pool"), tag = try column("tag")
        var records: [ImageRecord] = []
        for (n, row) in table.dropFirst().enumerated() where row.count == header.count {
            let label: Int
            switch row[kind] {
            case "generated": label = 1
            case "real": label = 0
            default: throw VeilGardeFailure.data("\(csv.path) row \(n + 2): class \(row[kind]) is neither real nor generated")
            }
            let file = row[name]
            records.append(ImageRecord(path: (label == 1 ? "generated/" : "real/") + file, label: label,
                                       stem: (file as NSString).deletingPathExtension, pool: row[pool], tag: row[tag]))
        }
        return ImageManifest(records: records, root: dataset)
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
