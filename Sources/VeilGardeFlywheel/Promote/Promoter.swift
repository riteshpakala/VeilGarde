//
//  Promoter.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The only writer of the live bundle. A promote takes one slot from a candidate bundle:
//        it checks the policy, snapshots live/, writes the new bytes beside the old and renames
//        them in, re-pins the manifest, runs the battery the slot needs, and either keeps the
//        change (logging it) or restores the snapshot (logging that). A rollback restores a
//        snapshot and runs the full battery.
//  PIN:  The order is the promote script's: back up, swap atomically, gate, keep or restore. Every
//        step that can be refused is checked before live/ is touched. The battery runs through an
//        injected closure, so the policy is testable without a GPU. promote_log.jsonl and
//        live/.history/ are bookkeeping; the bundle is every other file under live/.
//

import Foundation
import VeilGardeCore

public struct PromotionRecord: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case promote, refused, failed, rollback }
    public var date: Date
    public var kind: Kind
    public var slot: String
    public var candidate: String?
    public var fromSHA256: String?
    public var toSHA256: String?
    public var snapshot: String?
    public var battery: String?
    public var batteryReport: String?
    public var note: String?

    enum CodingKeys: String, CodingKey {
        case date, kind, slot, candidate, snapshot, battery, note
        case fromSHA256 = "from_sha256"
        case toSHA256 = "to_sha256"
        case batteryReport = "battery_report"
    }
}

public final class Promoter {
    public typealias Battery = (_ gate: BatterySpec.Gate, _ live: URL) throws -> BatteryReport

    public let area: FlywheelArea
    private let battery: Battery
    private let note: (String) -> Void

    public init(area: FlywheelArea, battery: @escaping Battery, note: @escaping (String) -> Void = { _ in }) {
        self.area = area
        self.battery = battery
        self.note = note
    }

    // MARK: Promote

    /// What a promote would change, every check already passed. Writes nothing but a refusal's log row.
    public struct Preview: Sendable, Equatable {
        public var slot: FlywheelSlot
        public var candidate: String
        public var current: Artifact?
        /// The artifact as the live manifest would record it.
        public var incoming: Artifact
        public var gate: BatterySpec.Gate
        public var data: Data

        public var summary: String {
            let from = current.map { "\($0.file) \($0.sha256.prefix(12))" } ?? "none"
            return "\(slot): \(from) → \(incoming.file) \(incoming.sha256.prefix(12)) (source \(incoming.source ?? "?")"
                + (incoming.parent.map { ", parent \($0.prefix(12))" } ?? "") + "); gate: the \(gate.rawValue) battery"
        }
    }

    public func preview(_ slot: FlywheelSlot, from candidateRoot: URL, store: FeatureStore? = nil) throws -> Preview {
        let live = try area.liveBundle()
        let candidate = try ModelBundle.load(candidateRoot)
        let candidateID = candidateRoot.lastPathComponent
        guard let incoming = candidate.manifest.artifact(slot.role, head: slot.head) else {
            throw VeilGardeFailure.missing("the candidate \(candidateID) has no \(slot) artifact")
        }
        let current = live.manifest.artifact(slot.role, head: slot.head)
        if incoming.sha256 == current?.sha256 { throw VeilGardeFailure.usage("\(slot) is already live with these bytes (\(incoming.sha256.prefix(12)))") }
        let data = try Data(contentsOf: candidate.root.appendingPathComponent(incoming.file))
        do {
            try check(slot, data: data, live: live, current: current, store: store)
        } catch {
            try log(PromotionRecord(date: Date(), kind: .refused, slot: "\(slot)", candidate: candidateID, fromSHA256: current?.sha256,
                                    toSHA256: incoming.sha256, note: "\(error)"))
            throw error
        }
        let file = targetFile(slot, current: current, candidateID: candidateID)
        let recorded = Artifact(role: slot.role, head: slot.head, file: file, sha256: incoming.sha256, bytes: data.count,
                                source: "candidates/\(candidateID)", parent: slot == .base ? current?.sha256 : incoming.parent)
        return Preview(slot: slot, candidate: candidateID, current: current, incoming: recorded, gate: FlywheelPolicy.gate(for: slot), data: data)
    }

    @discardableResult
    public func promote(_ slot: FlywheelSlot, from candidateRoot: URL, store: FeatureStore? = nil) throws -> PromotionRecord {
        let p = try preview(slot, from: candidateRoot, store: store)
        let live = try area.liveBundle()
        let candidateID = p.candidate, current = p.current, data = p.data
        let incoming = p.incoming

        // Back up, then write beside and rename in.
        let stamp = try snapshot()
        let file = incoming.file
        let target = area.live.appendingPathComponent(file)
        let staged = target.appendingPathExtension("cand")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: staged)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: target)
        }
        var manifest = live.manifest
        manifest.artifacts.removeAll { $0.role == slot.role && $0.head == slot.head }
        manifest.artifacts.append(incoming)
        manifest.history.append(BundleEvent(date: Date(), kind: .promote, slot: "\(slot)", fromSHA256: current?.sha256, toSHA256: incoming.sha256,
                                            note: "from candidates/\(candidateID)"))
        try JSONCoding.write(manifest, to: area.live.appendingPathComponent(BundleManifest.fileName))
        if let current, current.file != file { try? FileManager.default.removeItem(at: area.live.appendingPathComponent(current.file)) }
        _ = try area.liveBundle()

        // The gate.
        let gate = p.gate
        note("promote \(slot): running the \(gate.rawValue) battery on the live bundle")
        let report: BatteryReport
        do { report = try battery(gate, area.live) } catch {
            try restore(stamp)
            try log(PromotionRecord(date: Date(), kind: .failed, slot: "\(slot)", candidate: candidateID, fromSHA256: current?.sha256,
                                    toSHA256: incoming.sha256, snapshot: stamp, note: "the battery could not run: \(error); restored"))
            throw error
        }
        let reportURL = try save(report)
        guard report.pass else {
            try restore(stamp)
            try log(PromotionRecord(date: Date(), kind: .failed, slot: "\(slot)", candidate: candidateID, fromSHA256: current?.sha256,
                                    toSHA256: incoming.sha256, snapshot: stamp, battery: "FAIL", batteryReport: reportURL.path, note: "restored"))
            throw VeilGardeFailure.data("the \(gate.rawValue) battery failed; the live bundle is restored (\(reportURL.path))")
        }
        let record = PromotionRecord(date: Date(), kind: .promote, slot: "\(slot)", candidate: candidateID, fromSHA256: current?.sha256,
                                     toSHA256: incoming.sha256, snapshot: stamp, battery: "PASS", batteryReport: reportURL.path)
        try log(record)
        return record
    }

    /// Everything that must hold before live/ is touched.
    func check(_ slot: FlywheelSlot, data: Data, live: ModelBundle, current: Artifact?, store: FeatureStore?) throws {
        switch slot {
        case .base:
            guard let current else { throw VeilGardeFailure.data("the live bundle has no fusion head to continue") }
            let previous = try GBDTModel.load(live.root.appendingPathComponent(current.file))
            let next = try GBDTModel.decode(xgboostJSON: data)
            guard next.trees.count > previous.trees.count,
                  zip(previous.trees, next.trees).allSatisfy({ $0.raw != nil && $0.raw == $1.raw }) else {
                throw VeilGardeFailure.usage("the base moves only by a warm start of the live head: the candidate does not keep the live head's \(previous.trees.count) trees byte for byte")
            }
        case .combiner:
            let c = try JSONDecoder().decode(StackCombiner.self, from: data)
            guard c.wBase >= 0, c.wRescue >= 0, c.wGen.allSatisfy({ $0 >= 0 }) else {
                throw VeilGardeFailure.usage("a combiner's evidence weights must all be ≥ 0")
            }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["w_np"] != nil {
                throw VeilGardeFailure.usage("the combiner carries a noiseprint term (w_np), which the detector no longer reads")
            }
        case .head(let kind):
            let head = try LinearHead(data: data)
            if FlywheelPolicy.admissionHeads.contains(kind) {
                guard let store else { throw VeilGardeFailure.usage("the \(kind.rawValue) head's admission gate needs the store") }
                let a = try FlywheelPolicy.admission(head, store: store)
                note(String(format: "admission %@: block@0.8 %.1f%% on %d golden reals (bar 10%%)", kind.rawValue, a.block * 100, a.anchors))
                guard a.admitted else {
                    throw VeilGardeFailure.usage(String(format: "admission failed: the %@ head blocks %.1f%% of calm golden reals at 0.8 (bar 10%%)", kind.rawValue, a.block * 100))
                }
            }
        }
    }

    func targetFile(_ slot: FlywheelSlot, current: Artifact?, candidateID: String) -> String {
        switch slot {
        case .base, .combiner:
            return current?.file ?? (slot == .base ? "fusion_head.xgb.json" : "stack_combiner_v3.json")
        case .head(let kind):
            let tag = candidateID.replacingOccurrences(of: "/", with: "-")
            return HeadTrainer.fileName(kind, version: tag)
        }
    }

    // MARK: Rollback

    /// Restores `stamp` (the newest snapshot when nil), after snapshotting the current live/.
    @discardableResult
    public func rollback(to stamp: String? = nil) throws -> PromotionRecord {
        let snapshots = self.snapshots()
        guard let target = stamp ?? snapshots.last else { throw VeilGardeFailure.missing("live/.history holds no snapshot to roll back to") }
        guard snapshots.contains(target) else { throw VeilGardeFailure.missing("no snapshot \(target) in live/.history") }
        let before = try area.liveBundle(verify: false).manifest
        let saved = try snapshot(suffix: "before-rollback")
        try restore(target)
        let after = try area.liveBundle().manifest
        let report = try battery(.full, area.live)
        let reportURL = try save(report)
        let record = PromotionRecord(date: Date(), kind: .rollback, slot: "*", fromSHA256: ContentHash.sha256Hex(try JSONCoding.prettyEncoder().encode(before)),
                                     toSHA256: ContentHash.sha256Hex(try JSONCoding.prettyEncoder().encode(after)), snapshot: target,
                                     battery: report.pass ? "PASS" : "FAIL", batteryReport: reportURL.path, note: "the bundle before it is \(saved)")
        try log(record)
        return record
    }

    /// The snapshots in live/.history, oldest first. A rollback snapshots the bundle it replaces
    /// ("…-before-rollback"), so a second rollback undoes the first.
    public func snapshots() -> [String] { WorkArea.listing(area.history).sorted() }

    // MARK: Bookkeeping

    /// Copies every bundle file of live/ into live/.history/<stamp>/.
    func snapshot(suffix: String? = nil) throws -> String {
        var stamp = FlywheelArea.stamp() + (suffix.map { "-\($0)" } ?? "")
        let fm = FileManager.default
        var n = 1
        while fm.fileExists(atPath: area.history.appendingPathComponent(stamp).path) { n += 1; stamp = FlywheelArea.stamp() + "-\(n)" + (suffix.map { "-\($0)" } ?? "") }
        let target = area.history.appendingPathComponent(stamp, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for relative in try area.liveHashes().keys.sorted() {
            let to = target.appendingPathComponent(relative)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: area.live.appendingPathComponent(relative), to: to)
        }
        return stamp
    }

    /// Makes live/'s bundle files exactly the snapshot's.
    func restore(_ stamp: String) throws {
        let fm = FileManager.default
        let source = area.history.appendingPathComponent(stamp, isDirectory: true)
        let wanted = try area.hashes(of: source)
        for relative in try area.liveHashes().keys where wanted[relative] == nil {
            try fm.removeItem(at: area.live.appendingPathComponent(relative))
        }
        for relative in wanted.keys.sorted() {
            let to = area.live.appendingPathComponent(relative)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.copyItem(at: source.appendingPathComponent(relative), to: to)
        }
        _ = try area.liveBundle()
    }

    func save(_ report: BatteryReport) throws -> URL {
        let url = area.batteryRuns.appendingPathComponent("\(FlywheelArea.stamp())-\(report.gate.rawValue).json")
        try JSONCoding.write(report, to: url)
        return url
    }

    func log(_ record: PromotionRecord) throws {
        try JSONLWriter(url: area.promoteLog).append(record)
    }
}

extension FlywheelArea {
    /// Every regular file under `directory`, relative path → SHA-256.
    func hashes(of directory: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        let base = directory.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, !url.lastPathComponent.hasPrefix("._") else { continue }
            out[String(url.standardizedFileURL.path.dropFirst(base.count))] = try ContentHash.sha256Hex(fileAt: url)
        }
        return out
    }
}
