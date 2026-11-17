//
//  SignatureStoreTests.swift
//  VeilWatermarkTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The signature store on disk: insert, read back equal, update, remove; a taken id refused; eight
//        threads inserting at once losing nothing and never letting one id in twice; the PNG index; a
//        record whose cid was edited refused; AppleDouble sidecars and dot files never read as records;
//        a folder that is someone else's manifest refused.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilWatermark

@Suite("The signature store")
struct SignatureStoreTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vgm1-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("insert, read back equal, look up by PNG, update, remove")
    func crud() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SignatureStore(directory: dir)
        let record = MarkFixture.record()
        try store.insert(record)
        #expect(try store.record(for: record.id) == record)
        #expect(try store.record(forPNGSHA256: record.pngSHA256.uppercased()) == record)
        #expect(try store.records() == [record])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("records/01/0123456789abcdef.json").path))
        #expect(throws: SignatureStoreError.exists(record.id)) { try store.insert(record) }

        var renamed = record
        renamed.label = "Ana, 2026"
        try store.update(renamed)
        #expect(try store.record(for: record.id)?.label == "Ana, 2026")
        #expect(throws: SignatureStoreError.notFound(WatermarkID(42))) { try store.update(MarkFixture.record(id: WatermarkID(42))) }

        try store.remove(record.id)
        #expect(try store.record(for: record.id) == nil)
        #expect(try store.record(forPNGSHA256: record.pngSHA256) == nil)
        #expect(try store.records().isEmpty)
        #expect(throws: SignatureStoreError.notFound(record.id)) { try store.remove(record.id) }
        #expect(try store.record(for: try store.unusedID()) == nil)

        // The manifest names the format; a reopened store reads what the first wrote.
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("store.json"))) as? [String: Any]
        #expect(manifest?["format"] as? String == "veilgarde-signature-store" && manifest?["version"] as? Int == 1)
        try store.insert(record)
        #expect(try SignatureStore(directory: dir).record(for: record.id) == record)
    }

    @Test("eight threads inserting fifty each lose nothing; two racing for one id, exactly one wins")
    func concurrentInserts() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SignatureStore(directory: dir)
        let failures = Counter()
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for k in 0..<50 {
                let id = WatermarkID(UInt64(thread) << 32 | UInt64(k))
                do { try store.insert(MarkFixture.record(id: id, seed: UInt64(k))) } catch { failures.add() }
            }
        }
        #expect(failures.value == 0)
        #expect(try store.records().count == 400)

        let wins = Counter(), losses = Counter()
        let contested = MarkFixture.record(id: WatermarkID(0xfeed))
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do { try store.insert(contested); wins.add() } catch SignatureStoreError.exists(_) { losses.add() } catch {}
        }
        #expect(wins.value == 1 && losses.value == 7)
    }

    @Test("an edited record is refused, and left out of the list; sidecars and dot files are not records")
    func damage() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SignatureStore(directory: dir)
        let good = MarkFixture.record(id: WatermarkID(1), seed: 1)
        let bad = MarkFixture.record(id: WatermarkID(2), seed: 2)
        try store.insert(good)
        try store.insert(bad)
        // Edit the second record's cid on disk.
        let badURL = dir.appendingPathComponent("records/00/0000000000000002.json")
        var text = try String(contentsOf: badURL, encoding: .utf8)
        text = text.replacingOccurrences(of: bad.cid, with: String(repeating: "0", count: 64))
        try text.write(to: badURL, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { _ = try store.record(for: bad.id) }
        // A record filed under another id's name is refused too.
        try FileManager.default.copyItem(at: dir.appendingPathComponent("records/00/0000000000000001.json"),
                                         to: dir.appendingPathComponent("records/00/0000000000000003.json"))
        #expect(throws: (any Error).self) { _ = try store.record(for: WatermarkID(3)) }
        // exFAT's AppleDouble sidecars and stray temporaries.
        try Data("junk".utf8).write(to: dir.appendingPathComponent("records/00/._0000000000000001.json"))
        try Data("junk".utf8).write(to: dir.appendingPathComponent("records/00/.tmp-left-behind"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("records/._00"), withIntermediateDirectories: true)
        #expect(try store.records() == [good])
    }

    @Test("a folder holding another format's manifest is not opened")
    func foreign() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{\"format\": \"something-else\", \"version\": 1}".utf8).write(to: dir.appendingPathComponent("store.json"))
        #expect(throws: (any Error).self) { _ = try SignatureStore(directory: dir) }
        try Data("{\"format\": \"veilgarde-signature-store\", \"version\": 9}".utf8).write(to: dir.appendingPathComponent("store.json"))
        #expect(throws: (any Error).self) { _ = try SignatureStore(directory: dir) }
    }

    @Test("a record's JSON round-trips, whole seconds, its messageBits from the fingerprint")
    func recordJSON() throws {
        let record = SignatureRecord(id: MarkFixture.id, label: nil, keyFingerprint: WatermarkKey.default.fingerprint,
                                     signature: MarkFixture.record().signature, pngSHA256: "ab", width: 1, height: 1, sourceName: nil,
                                     createdAt: Date(timeIntervalSince1970: 1_795_000_000.75), settings: .default, report: MarkFixture.report())
        #expect(record.createdAt == Date(timeIntervalSince1970: 1_795_000_000))
        #expect(record.cid == record.signature.cid && record.format == "veilgarde-mark-record" && record.mark == "vgm1")
        let data = try SignatureStore.encoder.encode(record)
        #expect(try SignatureStore.decoder.decode(SignatureRecord.self, from: data) == record)
        #expect(record.messageBits == PayloadCode.message(id: MarkFixture.id, key: .default))
    }
}

/// A count several threads add to.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
