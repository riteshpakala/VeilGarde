//
//  BurgundySeal.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The Burgundy Seal — "pixels may change, but neighbourhoods rarely do". `seal` reads a
//        picture's anchors, their patterns and warp residual, walks its paths and keeps the signature
//        in a store; with `interlace` it also hides the seal's id in a copy, so the copy says it is
//        sealed. `detect` reads a found picture the same way and says which stored seal it holds, how
//        much of the original and how sure, and what any interlace carried.
//  PIN:  One workload at a time in a process (and across processes with `configure(lockFile:)`). The
//        interlace is vgm1 carrying the id until the anchor interlace passes the kill criterion; a
//        message of one's own is refused until then. An interlaced seal is formed from the interlaced
//        PNG as decoded and keeps the id of the picture's own seal. Sealing a picture already sealed
//        under the same key returns that seal (its label replaced when a new one is given).
//

import CoreGraphics
import Darwin
import Foundation
import VeilGardeCore
import VeilGardeLens

/// What `seal` hides in a copy.
public enum Interlace: Sendable, Equatable {
    /// The seal's own id.
    case signature
    /// A person's own words (up to 16 bytes).
    case message(String)
}

public struct SealedPicture: Sendable {
    public var record: SealRecord
    /// The interlaced copy (PNG), when one was asked for.
    public var interlaced: Data?
    /// The store already held this seal.
    public var existing: Bool
}

public enum SealProgress: String, Sendable {
    case reading, interlacing, walking, keeping, searching
}

public enum SealFailure: Error, Equatable, LocalizedError, CustomStringConvertible {
    case noAnchors
    case alreadyInterlaced(SealID)
    case tooSmallToInterlace(tiles: Int, needed: Int)
    case messageNotYet

    public var errorDescription: String? {
        switch self {
        case .noAnchors: return "the picture has no neighbourhood steady enough to anchor a seal (too small, or flat)"
        case .alreadyInterlaced(let id): return "the picture already carries an interlace naming \(id.hex)"
        case .tooSmallToInterlace(let tiles, let needed):
            return "the picture reads as \(tiles) tiles of 32 px; an interlace needs \(needed) (about 1 MP); seal it without one"
        case .messageNotYet:
            return "a message of your own needs the anchor interlace, which is still being measured; interlace the seal's id for now"
        }
    }

    public var description: String { errorDescription ?? "seal failure" }
}

/// Stops a running workload between stages.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public enum BurgundySeal {
    public static let motto = "Pixels may change, but neighbourhoods rarely do."

    // MARK: One workload at a time

    private static let gate = NSLock()
    private static let lockFileGuard = NSLock()
    nonisolated(unsafe) private static var lockFile: URL?

    /// Also take an flock on `lockFile` around every seal and detect (nil stops).
    public static func configure(lockFile url: URL?) {
        lockFileGuard.lock()
        lockFile = url
        lockFileGuard.unlock()
    }

    static func exclusive<T>(_ body: () throws -> T) throws -> T {
        gate.lock()
        defer { gate.unlock() }
        lockFileGuard.lock()
        let url = lockFile
        lockFileGuard.unlock()
        guard let url else { return try body() }
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw VeilGardeFailure.unavailable("cannot open the lock file \(url.path): errno \(errno)") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw VeilGardeFailure.unavailable("cannot lock \(url.path): errno \(errno)") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// The measure new seals are read with (decision-156: phase, measured against hsl, structure and census).
    public static let defaultMeasure = "phase"

    static func measure(_ key: SealKey) -> any NeighbourhoodMeasure { NeighbourhoodMeasures.named(defaultMeasure, key: key)! }

    // MARK: Seal

    public static func seal(contentsOf url: URL, label: String? = nil, store: SealStore?, key: SealKey = .default,
                            interlace: Interlace? = nil, progress: ((SealProgress) -> Void)? = nil, cancel: CancelFlag? = nil) throws -> SealedPicture {
        try seal(data: try Data(contentsOf: url), name: url.lastPathComponent, label: label, store: store, key: key, interlace: interlace,
                 progress: progress, cancel: cancel)
    }

    public static func seal(data: Data, name: String, label: String? = nil, store: SealStore?, key: SealKey = .default,
                            interlace: Interlace? = nil, progress: ((SealProgress) -> Void)? = nil, cancel: CancelFlag? = nil) throws -> SealedPicture {
        try exclusive {
            defer { LensRuntime.releaseMemory() }
            let cg = try ImageDecoding.cgImage(data: data, name: name)
            let facts = SealImageFacts(width: cg.width, height: cg.height, sha256: ContentHash.sha256Hex(data), name: name)
            if case .message = interlace { throw SealFailure.messageNotYet }
            progress?(.reading)
            let pattern = measure(key)
            let source = try AnchorReading.read(cg, key: key, measure: pattern, count: AnchorReading.sealCount, residual: true)
            guard source.anchors.count >= SealSearch.foundInliers else { throw SealFailure.noAnchors }
            if cancel?.isCancelled == true { throw CancellationError() }
            progress?(.walking)
            let paths = PathWalker.walk(source.anchors, pointerBits: pattern.pointerBits)
            var record = try SealRecord(id: nil, label: label, keyFingerprint: key.fingerprint, measure: pattern.name, image: facts,
                                        anchors: source.anchors, paths: paths, interlace: nil)
            var copy: Data?
            if interlace == .signature {
                progress?(.interlacing)
                let marked = try interlaceMark(cg, id: record.id, key: key, cancel: cancel)
                let decoded = try ImageDecoding.cgImage(data: marked.png, name: name)
                let reading = try AnchorReading.read(decoded, key: key, measure: pattern, count: AnchorReading.sealCount, residual: true)
                progress?(.walking)
                let interlacedFacts = SealImageFacts(width: decoded.width, height: decoded.height, sha256: ContentHash.sha256Hex(marked.png), name: name)
                record = try SealRecord(id: record.id, label: label, keyFingerprint: key.fingerprint, measure: pattern.name, image: interlacedFacts,
                                        anchors: reading.anchors, paths: PathWalker.walk(reading.anchors, pointerBits: pattern.pointerBits),
                                        interlace: SealInterlaceFacts(carrier: "vgm1", payload: "signature", report: marked.report))
                copy = marked.png
            }
            progress?(.keeping)
            var existing = false
            if let store {
                if var held = try store.record(for: record.id), held.cid == record.cid {
                    existing = true
                    if let label, label != held.label {
                        held.label = label
                        try store.update(held)
                    }
                    record = held
                } else if try store.record(for: record.id) != nil {
                    try store.update(record)
                } else {
                    try store.insert(record)
                }
            }
            return SealedPicture(record: record, interlaced: copy, existing: existing)
        }
    }

    public static func seal(contentsOf url: URL, label: String? = nil, store: SealStore?, key: SealKey = .default,
                            interlace: Interlace? = nil, progress: (@Sendable (SealProgress) -> Void)? = nil,
                            cancel: CancelFlag? = nil) async throws -> SealedPicture {
        try await Task.detached(priority: .userInitiated) {
            try seal(contentsOf: url, label: label, store: store, key: key, interlace: interlace, progress: progress, cancel: cancel)
        }.value
    }

    /// vgm1 carrying `id`, until the anchor interlace replaces it.
    static func interlaceMark(_ cg: CGImage, id: SealID, key: SealKey, cancel: CancelFlag?) throws -> (png: Data, report: EmbedReport) {
        let room = MarkDecoder.window(width: cg.width, height: cg.height, maxTiles: .max)
        guard room.rows * room.cols >= MarkDecoder.minimumTiles else {
            throw SealFailure.tooSmallToInterlace(tiles: room.rows * room.cols, needed: MarkDecoder.minimumTiles)
        }
        var unsearched = MarkReadOptions.default
        unsearched.search = false
        if let found = MarkDecoder.read(try NativePlane(cg), key: key, options: unsearched).id { throw SealFailure.alreadyInterlaced(found) }
        let rgb = try ImageLoading.rgbPixels(cg, width: cg.width, height: cg.height)
        let out = try MarkEmbedder.embed(rgb: rgb, width: cg.width, height: cg.height, id: id, key: key, settings: .default,
                                         options: .default, progress: nil, cancelled: { cancel?.isCancelled ?? false })
        return (out.png, out.report)
    }

    // MARK: Detect

    public static func detect(contentsOf url: URL, store: SealStore?, key: SealKey = .default) throws -> SealDetection {
        try detect(data: try Data(contentsOf: url), name: url.lastPathComponent, store: store, key: key)
    }

    public static func detect(data: Data, name: String, store: SealStore?, key: SealKey = .default) throws -> SealDetection {
        try exclusive { try detectLocked(try ImageDecoding.cgImage(data: data, name: name), store: store, key: key) }
    }

    public static func detect(_ cg: CGImage, store: SealStore?, key: SealKey = .default) throws -> SealDetection {
        try exclusive { try detectLocked(cg, store: store, key: key) }
    }

    public static func detect(contentsOf url: URL, store: SealStore?, key: SealKey = .default) async throws -> SealDetection {
        try await Task.detached(priority: .userInitiated) { try detect(contentsOf: url, store: store, key: key) }.value
    }

    static func detectLocked(_ cg: CGImage, store: SealStore?, key: SealKey) throws -> SealDetection {
        let start = Date()
        defer { LensRuntime.releaseMemory() }
        let records = try store?.records() ?? []
        // Each seal is read with the measure it names: the default first, then any other the store holds.
        let names = [defaultMeasure] + Set(records.map(\.measure)).subtracting([defaultMeasure]).sorted()
        let measures = names.compactMap { NeighbourhoodMeasures.named($0, key: key) }
        let readings = try AnchorReading.read(cg, key: key, measures: measures, count: AnchorReading.searchCount, residual: true)
        let byName = Dictionary(uniqueKeysWithValues: zip(measures.map(\.name), zip(readings, measures.map(\.pointerBits))))
        let reading = readings[0]
        let score: (SealRecord) -> SealMatch? = { r in byName[r.measure].flatMap { SealSearch.score(r, in: $0.0, pointerBits: $0.1) } }
        let interlaced = MarkDecoder.read(try NativePlane(cg), key: key).id
        var match = SealSearch.best(records, score: score)
        var verdict = SealVerdict.none
        if let id = interlaced {
            if let named = records.first(where: { $0.id == id }) {
                let own = match?.id == id ? match : score(named)
                if let own, own.found {
                    match = own
                    verdict = .sealed
                } else if let own, own.inliers >= SealSearch.foundInliers / 2 {
                    match = own
                    verdict = .interlaceOnly
                } else {
                    verdict = match?.found == true ? .sealed : .contentMismatch
                    if verdict == .contentMismatch { match = own }
                }
            } else {
                verdict = match?.found == true ? .sealed : .unknownSeal
            }
        } else if match?.found == true {
            verdict = .sealed
        }
        var detection = SealDetection(verdict: verdict, match: match, interlaced: interlaced, width: cg.width, height: cg.height,
                                      anchors: reading.anchors.count, seals: records.count, keyFingerprint: key.fingerprint,
                                      seconds: Date().timeIntervalSince(start), summary: "")
        detection.summary = summary(detection, haveStore: store != nil)
        return detection
    }

    static func summary(_ d: SealDetection, haveStore: Bool) -> String {
        let name: (SealMatch) -> String = { m in m.label.map { "“\($0)” (\(m.id.hex))" } ?? m.id.hex }
        let strength: (SealMatch) -> String = { m in
            String(format: "%d anchors agree, %d of %d hops retraced, %.0f%% of the original at %.2f×", m.inliers, m.retraced, m.possible,
                   100 * m.coverage, m.scale)
        }
        switch d.verdict {
        case .sealed:
            guard let m = d.match else { return "sealed" }
            var line = "sealed: \(name(m)) — \(strength(m))"
            if let id = d.interlaced, id != m.id { line += "; its interlace names \(id.hex), which is not this seal" }
            return line
        case .interlaceOnly:
            let m = d.match
            return "interlace only: the copy names \(d.interlaced?.hex ?? "?")" + (m.map { ", whose seal reads only in part (\(strength($0)))" } ?? "")
        case .contentMismatch:
            return "content mismatch: the interlace names \(d.interlaced?.hex ?? "?"), but the picture holds none of that seal"
        case .unknownSeal:
            return haveStore ? "unknown seal: the interlace names \(d.interlaced?.hex ?? "?"), which the store does not hold"
                : "an interlace names \(d.interlaced?.hex ?? "?"); open a store to say whose it is"
        case .none:
            if !haveStore { return "no seal: no store to search, and no interlace" }
            if let m = d.match, m.inliers >= SealSearch.foundInliers, m.cells < SealSearch.foundCells {
                return "no seal among \(d.seals): \(name(m)) shares only a small region (\(m.cells) of 64 cells: a caption, a logo, a stamp), not the picture"
            }
            if let m = d.match, m.inliers >= SealSearch.foundInliers, m.agreement < SealSearch.foundAgreement {
                return "no seal among \(d.seals): \(name(m)) shares only scattered parts (\(Int((m.agreement * 100).rounded()))% of its anchors: an app's frame, a sticker), not the picture"
            }
            if let m = d.match, m.inliers > 0 { return "no seal among \(d.seals): the nearest, \(name(m)), \(strength(m))" }
            return "no seal among \(d.seals)"
        }
    }
}
