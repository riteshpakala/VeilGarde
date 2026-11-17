//
//  ImageMark.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The pixel mark for an app or an agent, through one door: mark an image with an id and keep its
//        record in a SignatureStore; detect a mark and say whose it is; draw what happened (a record's
//        digest, a detection's digest, an overlay on the image that was read). The rest of Mark/ is
//        the machinery under it.
//  PIN:  One MLX workload at a time: every embed and detect takes an in-process lock and, after
//        configure(lockFile:), an flock on that file, so processes sharing a GPU queue instead of
//        colliding (nothing here calls another locked door, so the flock never nests). Verdicts:
//        marked (an id read, its record found, and the image's passive codes match the record's
//        signature at an offset the mark's period agrees with); contentMismatch (an id read and found,
//        but the pixels are not the recorded image's: a mark carried onto other content, or forged
//        with the public key); unknownID (an id read that the store does not hold, or no store);
//        passiveMatch (no id read, but a stored signature matches the passive codes: the exact bytes
//        of a PNG the store made, else the best record over the reading's window reads, whose cost
//        grows with the store); none. Drawing takes no lock: it never touches MLX.
//  PIN:  An embed reads where an image marked whole keeps its mark (phase 0, `MarkReadOptions.search`
//        off), both to refuse one marked already and to verify its own: a mark cropped since is not
//        looked for. A detection searches every phase.
//

import CoreGraphics
import Darwin
import Foundation
import VeilGardeCore
import VeilGardeLens

/// A marked image: the PNG to hand back, and the record its id points at.
public struct MarkedImage: Sendable {
    public var png: Data
    public var record: SignatureRecord
    public var report: EmbedReport { record.report }

    public init(png: Data, record: SignatureRecord) {
        self.png = png
        self.record = record
    }
}

public enum MarkVerdict: String, Codable, Sendable, CaseIterable {
    case marked, contentMismatch, unknownID, passiveMatch, none

    /// The verdict in a person's words.
    public var words: String {
        switch self {
        case .marked: return "marked"
        case .contentMismatch: return "content mismatch"
        case .unknownID: return "unknown id"
        case .passiveMatch: return "passive match"
        case .none: return "no mark"
        }
    }
}

/// Which agreement an overlay tints: the passive codes against the record (when there is a match), the
/// mark's levels against the id read (over the reading's window), or the best one there is.
public enum OverlayLayer: String, Codable, Sendable, CaseIterable {
    case auto, mark, passive
}

public struct MarkDetection: Codable, Sendable {
    public var verdict: MarkVerdict
    public var reading: MarkReading
    /// The record the id (or the passive match) points at.
    public var record: SignatureRecord?
    /// The passive match against that record's signature.
    public var match: MatchResult?
    /// Per tile of the image at the match's phase: its passive codes against the record's.
    public var agreement: TileMap?
    /// Per tile of the reading's window: the mark's soft level against the level the id lays there.
    public var markMap: TileMap?
    /// Whether the passive match sits where the mark's period says (nil unless both exist).
    public var consistent: Bool?
    /// The image is, byte for byte, a PNG the store made.
    public var exactBytes: Bool
    public var keyFingerprint: String
    public var width: Int
    public var height: Int
    public var seconds: Double
    public var summary: String

    /// The same detection without its per-tile maps, for a short JSON answer.
    public var withoutMaps: MarkDetection {
        var copy = self
        copy.agreement = nil
        copy.markMap = nil
        copy.reading.codedSoft = []
        return copy
    }
}

public enum MarkFailure: Error, Equatable, LocalizedError, CustomStringConvertible {
    case alreadyMarked(WatermarkID)
    case tooSmall(tiles: Int, needed: Int)
    case idTaken(WatermarkID)

    public var errorDescription: String? {
        switch self {
        case .alreadyMarked(let id): return "the image already carries mark \(id.hex); mark it again only with force"
        case .tooSmall(let tiles, let needed): return "the image reads as \(tiles) tiles of 32 px; a mark needs \(needed) (about 1 MP) to read back"
        case .idTaken(let id): return "the store already holds id \(id.hex)"
        }
    }

    public var description: String { errorDescription ?? "mark failure" }
}

/// Set from any thread to stop an embed between optimiser steps.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    public init() {}

    public func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

public enum ImageMark {
    // MARK: One workload at a time

    private static let gate = NSLock()
    private static let lockFileGuard = NSLock()
    private static var lockFile: URL?

    /// Also take an flock on `lockFile` around every embed and detect (nil stops).
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

    // MARK: Embed

    /// Marks the image at `url` with `id` (an unused one when nil) and inserts its record into `store`.
    public static func embed(contentsOf url: URL, id: WatermarkID? = nil, label: String? = nil, store: SignatureStore? = nil,
                             key: WatermarkKey = .default, settings: MarkSettings = .default, options: MarkReadOptions = .default,
                             progress: ((MarkProgress) -> Void)? = nil, cancel: CancelFlag? = nil) throws -> MarkedImage {
        try embed(data: try Data(contentsOf: url), name: url.lastPathComponent, id: id, label: label, store: store, key: key,
                  settings: settings, options: options, progress: progress, cancel: cancel)
    }

    /// Marks encoded image bytes; `name` is the file it came from, by name only.
    public static func embed(data: Data, name: String, id: WatermarkID? = nil, label: String? = nil, store: SignatureStore? = nil,
                             key: WatermarkKey = .default, settings: MarkSettings = .default, options: MarkReadOptions = .default,
                             progress: ((MarkProgress) -> Void)? = nil, cancel: CancelFlag? = nil) throws -> MarkedImage {
        try exclusive {
            let cg = try ImageDecoding.cgImage(data: data, name: name)
            return try embedLocked(cg, name: name, id: id, label: label, store: store, key: key, settings: settings, options: options,
                                   progress: progress, cancel: cancel)
        }
    }

    public static func embed(contentsOf url: URL, id: WatermarkID? = nil, label: String? = nil, store: SignatureStore? = nil,
                             key: WatermarkKey = .default, settings: MarkSettings = .default, options: MarkReadOptions = .default,
                             progress: ((MarkProgress) -> Void)? = nil) async throws -> MarkedImage {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try embed(contentsOf: url, id: id, label: label, store: store, key: key, settings: settings, options: options,
                          progress: progress, cancel: flag)
            }.value
        } onCancel: {
            flag.cancel()
        }
    }

    public static func embed(data: Data, name: String, id: WatermarkID? = nil, label: String? = nil, store: SignatureStore? = nil,
                             key: WatermarkKey = .default, settings: MarkSettings = .default, options: MarkReadOptions = .default,
                             progress: ((MarkProgress) -> Void)? = nil) async throws -> MarkedImage {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try embed(data: data, name: name, id: id, label: label, store: store, key: key, settings: settings, options: options,
                          progress: progress, cancel: flag)
            }.value
        } onCancel: {
            flag.cancel()
        }
    }

    static func embedLocked(_ cg: CGImage, name: String, id: WatermarkID?, label: String?, store: SignatureStore?, key: WatermarkKey,
                            settings: MarkSettings, options: MarkReadOptions, progress: ((MarkProgress) -> Void)?,
                            cancel: CancelFlag?) throws -> MarkedImage {
        let start = Date()
        defer { LensRuntime.releaseMemory() }
        let room = MarkDecoder.window(width: cg.width, height: cg.height, maxTiles: .max)
        guard room.rows * room.cols >= MarkDecoder.minimumTiles else {
            throw MarkFailure.tooSmall(tiles: room.rows * room.cols, needed: MarkDecoder.minimumTiles)
        }
        if !settings.force {
            // Where an image marked whole keeps its mark: a mark cropped since is not looked for, and is written over.
            progress?(MarkProgress(stage: .checking))
            var unsearched = options
            unsearched.search = false
            if let found = MarkDecoder.read(try NativePlane(cg), key: key, options: unsearched).id { throw MarkFailure.alreadyMarked(found) }
        }
        if cancel?.isCancelled == true { throw CancellationError() }
        let chosen: WatermarkID
        if let id {
            if try store?.record(for: id) != nil { throw MarkFailure.idTaken(id) }
            chosen = id
        } else {
            chosen = try store?.unusedID() ?? .random()
        }
        let rgb = try ImageLoading.rgbPixels(cg, width: cg.width, height: cg.height)
        let out = try MarkEmbedder.embed(rgb: rgb, width: cg.width, height: cg.height, id: chosen, key: key, settings: settings,
                                         options: options, progress: progress, cancelled: { cancel?.isCancelled ?? false })
        progress?(MarkProgress(stage: .signing, satisfied: out.report.satisfied, seconds: Date().timeIntervalSince(start)))
        let signature = try Watermark.sign(out.decoded)
        var report = out.report
        report.seconds = Date().timeIntervalSince(start)
        let record = SignatureRecord(id: chosen, label: label, keyFingerprint: key.fingerprint, signature: signature,
                                     pngSHA256: ContentHash.sha256Hex(out.png), width: cg.width, height: cg.height, sourceName: name,
                                     settings: settings, report: report)
        do {
            try store?.insert(record)
        } catch SignatureStoreError.exists(_) {
            throw MarkFailure.idTaken(chosen)
        }
        return MarkedImage(png: out.png, record: record)
    }

    // MARK: Detect

    /// Reads the image at `url` blind and says whose mark it carries, if any.
    public static func detect(contentsOf url: URL, store: SignatureStore?, key: WatermarkKey = .default,
                              options: MarkReadOptions = .default, passive: MatchOptions = .default) throws -> MarkDetection {
        try detect(data: try Data(contentsOf: url), name: url.lastPathComponent, store: store, key: key, options: options, passive: passive)
    }

    public static func detect(data: Data, name: String, store: SignatureStore?, key: WatermarkKey = .default,
                              options: MarkReadOptions = .default, passive: MatchOptions = .default) throws -> MarkDetection {
        try exclusive {
            let cg = try ImageDecoding.cgImage(data: data, name: name)
            return try detectLocked(cg, bytes: data, store: store, key: key, options: options, passive: passive)
        }
    }

    /// An already decoded image (no exact-bytes lookup).
    public static func detect(_ cg: CGImage, store: SignatureStore?, key: WatermarkKey = .default,
                              options: MarkReadOptions = .default, passive: MatchOptions = .default) throws -> MarkDetection {
        try exclusive { try detectLocked(cg, bytes: nil, store: store, key: key, options: options, passive: passive) }
    }

    public static func detect(contentsOf url: URL, store: SignatureStore?, key: WatermarkKey = .default,
                              options: MarkReadOptions = .default, passive: MatchOptions = .default) async throws -> MarkDetection {
        try await Task.detached(priority: .userInitiated) {
            try detect(data: try Data(contentsOf: url), name: url.lastPathComponent, store: store, key: key, options: options, passive: passive)
        }.value
    }

    static func detectLocked(_ cg: CGImage, bytes: Data?, store: SignatureStore?, key: WatermarkKey, options: MarkReadOptions,
                             passive: MatchOptions) throws -> MarkDetection {
        let start = Date()
        defer { LensRuntime.releaseMemory() }
        let plane = try NativePlane(cg)
        var exact: SignatureRecord?
        if let bytes, let store { exact = try store.record(forPNGSHA256: ContentHash.sha256Hex(bytes)) }
        let session = MarkDecoder.session(plane.array, width: plane.width, height: plane.height, key: key, options: options)
        let reading = session.reading
        var record: SignatureRecord?
        var match: MatchResult?
        var agreement: TileMap?
        var consistent: Bool?
        var verdict = MarkVerdict.none

        if let id = reading.id {
            if let found = try store?.record(for: id) {
                record = found
                let passiveRead = passiveMatch(plane, phaseX: reading.phaseX, phaseY: reading.phaseY, record: found, options: passive)
                match = passiveRead.match
                agreement = passiveRead.map
                let placed = passiveRead.match.map { $0.matched && periodAgrees($0, reading) } ?? false
                consistent = placed || exact?.id == id
                verdict = consistent == true ? .marked : .contentMismatch
            } else {
                verdict = .unknownID
            }
        } else if let store {
            if let exact {
                record = exact
                let passiveRead = passiveMatch(plane, phaseX: 0, phaseY: 0, record: exact, options: passive)
                match = passiveRead.match
                agreement = passiveRead.map
                verdict = .passiveMatch
            } else if let best = try bestStored(session.reads, records: store.records(), options: passive) {
                let passiveRead = passiveMatch(plane, phaseX: best.phaseX, phaseY: best.phaseY, record: best.record, options: passive)
                if let m = passiveRead.match, m.matched {
                    record = best.record
                    match = m
                    agreement = passiveRead.map
                    verdict = .passiveMatch
                }
            }
        }

        var detection = MarkDetection(verdict: verdict, reading: reading, record: record, match: match, agreement: agreement,
                                      markMap: session.markMap, consistent: consistent, exactBytes: exact != nil, keyFingerprint: key.fingerprint,
                                      width: cg.width, height: cg.height, seconds: Date().timeIntervalSince(start), summary: "")
        detection.summary = summary(detection, haveStore: store != nil)
        return detection
    }

    /// The image's passive codes at one phase against `record`'s signature, and where they agree.
    static func passiveMatch(_ plane: NativePlane, phaseX: Int, phaseY: Int, record: SignatureRecord,
                             options: MatchOptions) -> (match: MatchResult?, map: TileMap?) {
        let codes = TileCodeGrid(plane.fragility(originX: phaseX, originY: phaseY))
        let stored = record.signature.tileCodes
        guard let b = Matcher.best(crop: codes, stored: stored, margin: options.margin, minimumBits: options.minimumBits) else { return (nil, nil) }
        var m = MatchResult(offsetX: b.dx, offsetY: b.dy, phaseX: phaseX, phaseY: phaseY, score: b.score, bitsCompared: b.bits,
                            zScore: Matcher.zScore(score: b.score, bits: b.bits), matched: false)
        m.matched = m.score >= options.threshold && m.bitsCompared >= options.minimumBits
        return (m, Matcher.agreement(crop: codes, stored: stored, dx: b.dx, dy: b.dy, originX: phaseX, originY: phaseY))
    }

    /// Whether the match's tile offset carries the period cell the reading found at the phase grid's tile (0, 0).
    static func periodAgrees(_ m: MatchResult, _ reading: MarkReading) -> Bool {
        PayloadLayout.cell(row: m.offsetY - reading.periodRow, col: m.offsetX - reading.periodCol) == 0
    }

    /// The stored record whose signature best matches the reading's window reads, with its phase.
    static func bestStored(_ reads: [MarkDecoder.WindowRead], records: [SignatureRecord],
                           options: MatchOptions) throws -> (record: SignatureRecord, phaseX: Int, phaseY: Int)? {
        let windows = reads.map { (px: $0.phaseX, py: $0.phaseY, codes: TileCodeGrid($0.grid)) }
        var best: (record: SignatureRecord, phaseX: Int, phaseY: Int, score: Double, bits: Int)?
        for record in records {
            let stored = record.signature.tileCodes
            for w in windows {
                guard let b = Matcher.best(crop: w.codes, stored: stored, margin: options.margin, minimumBits: options.minimumBits) else { continue }
                if best == nil || b.score > best!.score || (b.score == best!.score && b.bits > best!.bits) {
                    best = (record, w.px, w.py, b.score, b.bits)
                }
            }
        }
        guard let best, best.score >= options.threshold else { return nil }
        return (best.record, best.phaseX, best.phaseY)
    }

    static func summary(_ d: MarkDetection, haveStore: Bool) -> String {
        let z = String(format: "%.1f", d.reading.pilotZ)
        let passive = d.match.map { String(format: "%.2f", $0.score) }
        let who = d.record?.label.map { " · recorded as “\($0)”" } ?? ""
        switch d.verdict {
        case .marked:
            return "Marked · id \(d.reading.id!.hex)\(who) · z \(z)" + (passive.map { " · passive \($0)" } ?? "")
        case .contentMismatch:
            return "Content mismatch · id \(d.reading.id!.hex) is recorded for another image" + (passive.map { " (passive \($0))" } ?? " (no passive match)")
        case .unknownID:
            return haveStore ? "Unknown id · \(d.reading.id!.hex) is not in this store · z \(z)"
                             : "Mark read · id \(d.reading.id!.hex) · z \(z) · no store to look it up in"
        case .passiveMatch:
            let id = d.record.map { " (id \($0.id.short))" } ?? ""
            let at = d.match.map { " at (\($0.pixelX), \($0.pixelY))" } ?? ""
            let exactly = d.exactBytes ? " · the exact PNG it made" : ""
            return "Passive match · no mark read, but the content matches\(who.isEmpty ? " a stored image" : who)\(id)" + (passive.map { " · \($0)\(at)" } ?? "") + exactly
        case .none:
            let small = d.reading.tiles < MarkDecoder.minimumTiles ? " (below the \(MarkDecoder.minimumTiles) tiles a reading needs)" : ""
            return "No mark · pilot z \(z) over \(d.reading.tiles) tiles\(small)"
        }
    }

    // MARK: Drawing

    /// A record's digest: its id, its payload bits and its signature's tile codes (640 × 800 PNG).
    public static func digest(_ record: SignatureRecord) throws -> Data { try MarkDigest.record(record) }

    /// A detection's digest: the bits read against the record's, the coded bits' reads and where the
    /// content agrees (640 × 800 PNG).
    public static func digest(_ detection: MarkDetection) throws -> Data { try MarkDigest.detection(detection) }

    /// The image that was read, its tiles tinted by agreement, under a header with the verdict (PNG).
    public static func overlay(_ detection: MarkDetection, queryContentsOf url: URL, layer: OverlayLayer = .auto) throws -> Data {
        try MarkOverlay.render(detection, query: try ImageDecoding.cgImage(contentsOf: url), layer: layer)
    }

    public static func overlay(_ detection: MarkDetection, query: CGImage, layer: OverlayLayer = .auto) throws -> Data {
        try MarkOverlay.render(detection, query: query, layer: layer)
    }
}
