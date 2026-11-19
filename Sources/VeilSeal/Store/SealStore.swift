//
//  SealStore.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A folder of mark records, looked up by the id a mark carries or by the exact bytes of a marked
//        PNG: one JSON file per record, safe to write from several processes at once, and nothing in it
//        but files (back it up by copying the folder). VeilGarde never picks where it lives; the caller
//        names the folder (an app's support folder, VEILGARDE_SEAL_STORE for the CLI).
//  PIN:  store.json holds the format and version; records/<hh>/<16 hex>.json one record; by-png/<hh>/<sha256>
//        the id of the PNG with that SHA-256 (hh: the first two hex digits). Every write goes to a temporary
//        file in the same folder and is renamed into place: an insert with renamex_np(RENAME_EXCL), else
//        link(2), else (exFAT has neither) a check then a rename. A read checks the record's id against
//        its file name and its cid against its words. AppleDouble sidecars (._*) are never records.
//

import Darwin
import Foundation
import VeilGardeCore

public enum SealStoreError: Error, Equatable, LocalizedError {
    case exists(SealID)
    case notFound(SealID)
    case corrupt(String)
    case foreign(String)

    public var errorDescription: String? {
        switch self {
        case .exists(let id): return "the store already holds id \(id.hex)"
        case .notFound(let id): return "the store holds no id \(id.hex)"
        case .corrupt(let why): return "a store record is damaged: \(why)"
        case .foreign(let why): return "not a VeilGarde signature store: \(why)"
        }
    }
}

public final class SealStore: @unchecked Sendable {
    public static let format = "veilgarde-signature-store"
    public static let version = 1

    public let directory: URL

    /// Opens the store in `directory`, making it when it does not exist.
    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        let fm = FileManager.default
        try fm.createDirectory(at: self.directory.appendingPathComponent("records"), withIntermediateDirectories: true)
        try fm.createDirectory(at: self.directory.appendingPathComponent("by-png"), withIntermediateDirectories: true)
        let manifest = self.directory.appendingPathComponent("store.json")
        if let data = try? Data(contentsOf: manifest) {
            struct Head: Decodable { let format: String; let version: Int }
            guard let head = try? JSONDecoder().decode(Head.self, from: data), head.format == Self.format else {
                throw SealStoreError.foreign("\(manifest.path) is not a \(Self.format) manifest")
            }
            guard head.version <= Self.version else { throw SealStoreError.foreign("store version \(head.version) is newer than \(Self.version)") }
        } else {
            let body = Data("{\n  \"format\" : \"\(Self.format)\",\n  \"version\" : \(Self.version)\n}\n".utf8)
            try? write(body, to: manifest, exclusive: true)
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func recordURL(_ id: SealID) -> URL {
        directory.appendingPathComponent("records/\(id.hex.prefix(2))/\(id.hex).json")
    }

    func pngURL(_ sha256: String) -> URL {
        let sha = sha256.lowercased()
        return directory.appendingPathComponent("by-png/\(sha.prefix(2))/\(sha)")
    }

    // MARK: Writing

    /// Adds a record; `.exists` when its id is taken.
    public func insert(_ record: SealRecord) throws {
        let body = try Self.encoder.encode(record)
        do {
            try write(body, to: recordURL(record.id), exclusive: true)
        } catch SealStoreError.exists(_) {
            throw SealStoreError.exists(record.id)
        }
        try indexPNG(record)
    }

    /// Replaces a record that exists.
    public func update(_ record: SealRecord) throws {
        guard FileManager.default.fileExists(atPath: recordURL(record.id).path) else { throw SealStoreError.notFound(record.id) }
        try write(try Self.encoder.encode(record), to: recordURL(record.id), exclusive: false)
        try indexPNG(record)
    }

    /// Removes a record and its PNG index entry.
    public func remove(_ id: SealID) throws {
        guard let record = try record(for: id) else { throw SealStoreError.notFound(id) }
        try? FileManager.default.removeItem(at: pngURL(record.pngSHA256))
        try FileManager.default.removeItem(at: recordURL(id))
    }

    private func indexPNG(_ record: SealRecord) throws {
        let url = pngURL(record.pngSHA256)
        let body = Data((record.id.hex + "\n").utf8)
        do {
            try write(body, to: url, exclusive: true)
        } catch SealStoreError.exists(_) {
            try write(body, to: url, exclusive: false)
        }
    }

    /// Writes `data` beside `url` and renames it into place; with `exclusive`, never over an existing file.
    private func write(_ data: Data, to url: URL, exclusive: Bool) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard exclusive else {
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw SealStoreError.corrupt("cannot rename into \(url.path): errno \(errno)") }
            return
        }
        if renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) == 0 { return }
        if errno == EEXIST { throw SealStoreError.exists(SealID(0)) }
        if link(temporary.path, url.path) == 0 { return }
        if errno == EEXIST { throw SealStoreError.exists(SealID(0)) }
        // Neither exclusive rename nor hard links (exFAT): check, then rename.
        if FileManager.default.fileExists(atPath: url.path) { throw SealStoreError.exists(SealID(0)) }
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw SealStoreError.corrupt("cannot rename into \(url.path): errno \(errno)") }
    }

    // MARK: Reading

    /// The record for `id`, nil when there is none; a damaged record throws.
    public func record(for id: SealID) throws -> SealRecord? {
        let url = recordURL(id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try check(data, named: id.hex, at: url)
    }

    /// The record of the marked PNG with this SHA-256, when the store made it.
    public func record(forPNGSHA256 sha256: String) throws -> SealRecord? {
        guard let text = try? String(contentsOf: pngURL(sha256), encoding: .utf8),
              let id = SealID(hex: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return try record(for: id)
    }

    /// Every readable record, by id; damaged files are left out.
    public func records() throws -> [SealRecord] {
        let root = directory.appendingPathComponent("records")
        let fm = FileManager.default
        var out: [SealRecord] = []
        for shard in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !shard.hasPrefix(".") {
            let folder = root.appendingPathComponent(shard)
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".json") && !name.hasPrefix(".") {
                let url = folder.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url), let record = try? check(data, named: String(name.dropLast(5)), at: url) else { continue }
                out.append(record)
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    /// An id no record holds yet.
    public func unusedID() throws -> SealID {
        while true {
            let id = SealID.random()
            if !FileManager.default.fileExists(atPath: recordURL(id).path) { return id }
        }
    }

    private func check(_ data: Data, named hex: String, at url: URL) throws -> SealRecord {
        let record: SealRecord
        do {
            record = try Self.decoder.decode(SealRecord.self, from: data)
        } catch {
            throw SealStoreError.corrupt("\(url.lastPathComponent) does not decode: \(error.localizedDescription)")
        }
        guard record.format == SealRecord.currentFormat else { throw SealStoreError.corrupt("\(url.lastPathComponent) is a \(record.format)") }
        guard record.id.hex == hex.lowercased() else { throw SealStoreError.corrupt("\(url.lastPathComponent) holds id \(record.id.hex)") }
        guard record.cid == record.signature.cid else { throw SealStoreError.corrupt("\(url.lastPathComponent)'s cid does not match its signature") }
        return record
    }
}
