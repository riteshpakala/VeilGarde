//
//  SealStoreTests.swift
//  VeilSealTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The seal store on disk: insert, read back equal, update, remove; a taken id refused; eight
//        threads inserting at once losing nothing and never letting one id in twice; a seal whose body
//        was edited refused; AppleDouble sidecars and dot files never read as seals; a folder that is
//        someone else's manifest refused; a seal's JSON round trip and its id from its cid.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilSeal

@Suite("The seal store")
struct SealStoreTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seal-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("insert, read back equal, update, remove")
    func crud() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SealStore(directory: dir)
        let record = MarkFixture.record()
        try store.insert(record)
        #expect(try store.record(for: record.id) == record)
        #expect(try store.records() == [record])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("seals/\(record.id.hex.prefix(2))/\(record.id.hex).json").path))
        #expect(throws: SealStoreError.exists(record.id)) { try store.insert(record) }

        var renamed = record
        renamed.label = "Ana, 2026"
        try store.update(renamed)
        #expect(try store.record(for: record.id)?.label == "Ana, 2026", "the label is outside the cid")
        #expect(throws: SealStoreError.notFound(SealID(42))) { try store.update(MarkFixture.record(id: SealID(42))) }

        try store.remove(record.id)
        #expect(try store.record(for: record.id) == nil)
        #expect(try store.records().isEmpty)
        #expect(throws: SealStoreError.notFound(record.id)) { try store.remove(record.id) }

        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("store.json"))) as? [String: Any]
        #expect(manifest?["format"] as? String == "veilgarde-seal-store" && manifest?["version"] as? Int == 1)
        try store.insert(record)
        #expect(try SealStore(directory: dir).record(for: record.id) == record)
    }

    @Test("eight threads inserting fifty each lose nothing; two racing for one id, exactly one wins")
    func concurrentInserts() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SealStore(directory: dir)
        let failures = Counter()
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            for k in 0..<50 {
                do { try store.insert(MarkFixture.record(seed: UInt64(t * 1000 + k), count: 8)) } catch { failures.add() }
            }
        }
        #expect(failures.value == 0)
        #expect(try store.records().count == 400)
        let wins = Counter()
        DispatchQueue.concurrentPerform(iterations: 2) { k in
            if (try? store.insert(MarkFixture.record(id: SealID(0xfeed), seed: UInt64(90_000 + k), count: 8))) != nil { wins.add() }
        }
        #expect(wins.value == 1)
    }

    @Test("an edited seal is refused, and left out of the list; sidecars and dot files are not seals")
    func damage() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SealStore(directory: dir)
        let good = MarkFixture.record(id: SealID(1), seed: 1)
        let bad = MarkFixture.record(id: SealID(2), seed: 2)
        try store.insert(good)
        try store.insert(bad)
        // Move one anchor of the second seal on disk: its cid no longer matches its body.
        let badURL = dir.appendingPathComponent("seals/00/0000000000000002.json")
        var text = try String(contentsOf: badURL, encoding: .utf8)
        text = text.replacingOccurrences(of: bad.anchors[0].code.hex, with: String(repeating: "0", count: 64))
        try text.write(to: badURL, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { _ = try store.record(for: bad.id) }
        // A seal filed under another id's name is refused too.
        try FileManager.default.copyItem(at: dir.appendingPathComponent("seals/00/0000000000000001.json"),
                                         to: dir.appendingPathComponent("seals/00/0000000000000003.json"))
        #expect(throws: (any Error).self) { _ = try store.record(for: SealID(3)) }
        try Data("junk".utf8).write(to: dir.appendingPathComponent("seals/00/._0000000000000001.json"))
        try Data("junk".utf8).write(to: dir.appendingPathComponent("seals/00/.tmp-left-behind"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("seals/._00"), withIntermediateDirectories: true)
        #expect(try store.records() == [good])
    }

    @Test("a folder holding another format's manifest is not opened")
    func foreign() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{\"format\": \"something-else\", \"version\": 1}".utf8).write(to: dir.appendingPathComponent("store.json"))
        #expect(throws: (any Error).self) { _ = try SealStore(directory: dir) }
        try Data("{\"format\": \"veilgarde-seal-store\", \"version\": 9}".utf8).write(to: dir.appendingPathComponent("store.json"))
        #expect(throws: (any Error).self) { _ = try SealStore(directory: dir) }
    }

    @Test("a seal's JSON round-trips in whole seconds; its id is its cid's first 16 hex digits; the label and date are outside the cid")
    func recordJSON() throws {
        let record = MarkFixture.record()
        #expect(record.format == "burgundy/1" && record.id.hex == String(record.cid.prefix(16)) && record.isIntact)
        let data = try SealStore.encoder.encode(record)
        #expect(try SealStore.decoder.decode(SealRecord.self, from: data) == record)
        #expect(MarkFixture.record(label: "someone else").cid == record.cid)
        #expect(MarkFixture.record(seed: 8).cid != record.cid)
        #expect(!record.signature().isEmpty && record.signature(limit: 12).count == 12)
    }
}

/// A count several threads add to.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
