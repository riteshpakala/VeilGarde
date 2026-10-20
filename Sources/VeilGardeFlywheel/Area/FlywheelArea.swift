//
//  FlywheelArea.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Where the flywheel keeps everything, under the work area:
//
//            live/                       the live bundle; promote is its only writer
//            live/.history/<stamp>/      a copy of live/ taken before every promote and rollback
//            live/promote_log.jsonl      one row per promote, refusal, failure and rollback
//            store/shards/               the features-only store
//            candidates/<id>/            training candidates (complete bundles)
//            battery/spec.json           the battery spec, copied at init
//            battery/baseline.json       the ratchet floors, copied at init
//            battery/images/             the battery's images, the spec's {IMAGES}
//            battery/retired/<stamp>/    a spec and floors that a newer shipped version replaced
//            battery/runs/<stamp>.json   every battery report
//            flywheel_metrics.csv        the north-star agreement, one row per measurement
//
//  PIN:  `initialize` seeds live/ from a verified bundle (the shipped one) with a seed event in its
//        history, and battery/ from the shipped spec and floors; it refuses a live/ that exists.
//        `replaceBattery` installs a newer shipped spec and floors in an area that has a live/,
//        keeping the old pair under battery/retired/, and never touches live/.
//        Every stage but promote and rollback opens live/ read-only.
//

import Foundation
import VeilGardeCore

public struct FlywheelArea: Sendable {
    public let area: WorkArea

    public init(_ area: WorkArea) { self.area = area }

    public var root: URL { area.root }
    public var live: URL { root.appendingPathComponent("live", isDirectory: true) }
    public var history: URL { live.appendingPathComponent(".history", isDirectory: true) }
    public var promoteLog: URL { live.appendingPathComponent("promote_log.jsonl") }
    public var store: URL { root.appendingPathComponent("store/shards", isDirectory: true) }
    public var candidates: URL { root.appendingPathComponent("candidates", isDirectory: true) }
    public var battery: URL { root.appendingPathComponent("battery", isDirectory: true) }
    public var batterySpec: URL { battery.appendingPathComponent("spec.json") }
    public var batteryBaseline: URL { battery.appendingPathComponent("baseline.json") }
    public var batteryRuns: URL { battery.appendingPathComponent("runs", isDirectory: true) }
    public var batteryImages: URL { battery.appendingPathComponent("images", isDirectory: true) }
    public var batteryRetired: URL { battery.appendingPathComponent("retired", isDirectory: true) }
    public var metricsCSV: URL { root.appendingPathComponent("flywheel_metrics.csv") }

    /// Names in live/ that are the flywheel's bookkeeping, not the bundle.
    public static let bookkeeping: Set<String> = [".history", "promote_log.jsonl", ".DS_Store"]

    public var isInitialized: Bool { FileManager.default.fileExists(atPath: live.appendingPathComponent(BundleManifest.fileName).path) }

    public func liveBundle(verify: Bool = true) throws -> ModelBundle {
        guard isInitialized else {
            throw VeilGardeFailure.missing("no live bundle at \(live.path)", hint: "run `veilgarde flywheel init` first")
        }
        return try ModelBundle.load(live, verify: verify)
    }

    public struct InitReport: Codable, Sendable, Equatable {
        public var artifacts: Int
        public var batterySpecSHA256: String
        public var batteryBaselineSHA256: String
    }

    /// Seeds live/ from `bundle` and battery/ from the given spec and floors.
    @discardableResult
    public func initialize(from bundle: ModelBundle, spec: Data, baseline: Data, note: String = "seeded from the shipped bundle") throws -> InitReport {
        let fm = FileManager.default
        if isInitialized { throw VeilGardeFailure.exists("the live bundle already exists at \(live.path)", hint: "promote and rollback change it; init seeds it once") }
        try bundle.verify()
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        for artifact in bundle.manifest.artifacts {
            let to = live.appendingPathComponent(artifact.file)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.copyItem(at: bundle.root.appendingPathComponent(artifact.file), to: to)
        }
        var manifest = BundleManifest(artifacts: bundle.manifest.artifacts, weights: bundle.manifest.weights, history: bundle.manifest.history)
        manifest.history.append(BundleEvent(date: Date(), kind: .seed, slot: "*", note: note))
        try JSONCoding.write(manifest, to: live.appendingPathComponent(BundleManifest.fileName))
        try fm.createDirectory(at: battery, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: batterySpec.path) { try spec.write(to: batterySpec) }
        if !fm.fileExists(atPath: batteryBaseline.path) { try baseline.write(to: batteryBaseline) }
        _ = try liveBundle()
        return InitReport(artifacts: manifest.artifacts.count, batterySpecSHA256: try ContentHash.sha256Hex(fileAt: batterySpec),
                          batteryBaselineSHA256: try ContentHash.sha256Hex(fileAt: batteryBaseline))
    }

    public struct BatteryReplacement: Codable, Sendable, Equatable {
        /// Where the replaced spec and floors were kept; nil when there were none or they were already these.
        public var retired: String?
        public var batterySpecSHA256: String
        public var batteryBaselineSHA256: String
    }

    /// Installs `spec` and `baseline` as battery/spec.json and baseline.json. The pair they replace
    /// moves to battery/retired/<stamp>/ first, so a newer spec version never loses the old floors.
    @discardableResult
    public func replaceBattery(spec: Data, baseline: Data, date: Date = Date()) throws -> BatteryReplacement {
        let fm = FileManager.default
        try fm.createDirectory(at: battery, withIntermediateDirectories: true)
        let same = (try? Data(contentsOf: batterySpec)) == spec && (try? Data(contentsOf: batteryBaseline)) == baseline
        var retired: String?
        let old = [batterySpec, batteryBaseline].filter { fm.fileExists(atPath: $0.path) }
        if !same && !old.isEmpty {
            let folder = batteryRetired.appendingPathComponent(Self.stamp(date), isDirectory: true)
            if fm.fileExists(atPath: folder.path) { throw VeilGardeFailure.exists("\(folder.path) already exists", hint: "wait a second and run it again") }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for url in old { try fm.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent)) }
            retired = folder.path
        }
        if !same {
            try spec.write(to: batterySpec, options: .atomic)
            try baseline.write(to: batteryBaseline, options: .atomic)
        }
        _ = try BatterySpec.load(batterySpec)
        return BatteryReplacement(retired: retired, batterySpecSHA256: try ContentHash.sha256Hex(fileAt: batterySpec),
                                  batteryBaselineSHA256: try ContentHash.sha256Hex(fileAt: batteryBaseline))
    }

    /// Every bundle file in live/ (bookkeeping excluded), relative path → SHA-256.
    public func liveHashes() throws -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: live, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        let base = live.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
            let first = relative.split(separator: "/").first.map(String.init) ?? relative
            if Self.bookkeeping.contains(first) { walker.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if url.lastPathComponent.hasPrefix("._") { continue }
            out[relative] = try ContentHash.sha256Hex(fileAt: url)
        }
        return out
    }

    /// A UTC stamp that sorts in time order (and a suffix when two land in one second).
    public static func stamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }
}
