//
//  SealStore.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A folder of seals (burgundy/1 records), looked up by id or read whole when a found picture is
//        searched: one JSON file per seal, safe to write from several processes at once, and nothing in
//        it but files (back it up by copying the folder). VeilGarde never picks where it lives; the
//        caller names the folder (VeilAgent's `<support>/seals`, VEILGARDE_SEAL_STORE for the CLI).
//  PIN:  store.json holds the format and version; seals/<hh>/<16 hex>.json one seal (hh: its first two
//        hex digits). Every write goes to a temporary file in the same folder and is renamed into place:
//        an insert with renamex_np(RENAME_EXCL), else link(2), else (exFAT has neither) a check then a
//        rename. A read checks the seal's id against its file name and its cid against its body.
//        AppleDouble sidecars (._*) are never seals.
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
        case .exists(let id): return "the store already holds seal \(id.hex)"
        case .notFound(let id): return "the store holds no seal \(id.hex)"
        case .corrupt(let why): return "a seal is damaged: \(why)"
        case .foreign(let why): return "not a VeilGarde seal store: \(why)"
        }
    }
}

public final class SealStore: @unchecked Sendable {
    public static let format = "veilgarde-seal-store"
    public static let version = 1

    public let directory: URL

    /// Opens the store in `directory`, making it when it does not exist.
    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: self.directory.appendingPathComponent("seals"), withIntermediateDirectories: true)
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
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func url(_ id: SealID) -> URL {
        directory.appendingPathComponent("seals/\(id.hex.prefix(2))/\(id.hex).json")
    }

    // MARK: Writing

    /// Adds a seal; `.exists` when its id is taken.
    public func insert(_ record: SealRecord) throws {
        do {
            try write(try Self.encoder.encode(record), to: url(record.id), exclusive: true)
        } catch SealStoreError.exists(_) {
            throw SealStoreError.exists(record.id)
        }
    }

    /// Replaces a seal that exists.
    public func update(_ record: SealRecord) throws {
        guard FileManager.default.fileExists(atPath: url(record.id).path) else { throw SealStoreError.notFound(record.id) }
        try write(try Self.encoder.encode(record), to: url(record.id), exclusive: false)
    }

    public func remove(_ id: SealID) throws {
        guard FileManager.default.fileExists(atPath: url(id).path) else { throw SealStoreError.notFound(id) }
        try FileManager.default.removeItem(at: url(id))
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

    /// The seal for `id`, nil when there is none; a damaged seal throws.
    public func record(for id: SealID) throws -> SealRecord? {
        let url = url(id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try check(data, named: id.hex, at: url)
    }

    /// Every readable seal, by id; damaged files are left out.
    public func records() throws -> [SealRecord] {
        let root = directory.appendingPathComponent("seals")
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

    private func check(_ data: Data, named hex: String, at url: URL) throws -> SealRecord {
        let record: SealRecord
        do {
            record = try Self.decoder.decode(SealRecord.self, from: data)
        } catch {
            throw SealStoreError.corrupt("\(url.lastPathComponent) does not decode: \(error.localizedDescription)")
        }
        guard record.format == SealRecord.currentFormat else { throw SealStoreError.corrupt("\(url.lastPathComponent) is a \(record.format)") }
        guard record.id.hex == hex.lowercased() else { throw SealStoreError.corrupt("\(url.lastPathComponent) holds seal \(record.id.hex)") }
        guard record.isIntact else { throw SealStoreError.corrupt("\(url.lastPathComponent)'s cid does not match its body") }
        return record
    }
}
