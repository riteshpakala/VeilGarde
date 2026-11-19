//
//  SealAcceptance.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Whether the Burgundy Seal holds, measured against decision-155's bars: a sample of
//        final_mixed sealed into one store, every SealChange of every picture detected against the
//        whole store, and pictures never sealed detected the same way (the null). Each copy's row
//        keeps its own seal's reading and every other seal that came near, so the found thresholds
//        can be swept afterwards; each change also keeps how many of the seal's anchors the copy
//        holds again where the fitted transform puts them, and which of their 256 bits flipped.
//  PIN:  A picture is decoded with its orientation applied and scaled to a long side of at most
//        2048 (never up): that is the picture sealed and changed. Anchors and codes only (no warp
//        residual): the found rule does not read the residual, and leaving MLX out lets the
//        pictures run in parallel on the CPU. A copy is found when its own seal passes the
//        thresholds and no other seal outranks it (found first, then inliers, then hops); a false
//        match is any other seal found. Rows are appended as each picture finishes.
//

import CoreGraphics
import Foundation
import ImageIO
import VeilGardeCore
import VeilGardeLens

public struct SealAcceptanceSettings: Codable, Sendable {
    public var seed: UInt64 = 0
    public var perLabel = 100
    public var nullSeed: UInt64 = 2
    public var nullPerLabel = 50
    /// Samples whose pictures are left out of both the sealed and the null pictures.
    public var excluding: [UInt64] = []
    public var longSide = 2048
    public var changes: [SealChange] = SealChange.allCases
    public var foundInliers = SealSearch.foundInliers
    public var foundHops = SealSearch.foundHops
    /// The neighbourhood measure the seals are read with (NeighbourhoodMeasures).
    public var measure = BurgundySeal.defaultMeasure
    /// How anchors are kept (strength, or the warp's fragility: that reads the residual on the GPU, one picture at a time).
    public var selection = AnchorSelection.strength
    /// AnchorFinder's weak floor for the run (equal to its contrast: no weak anchors).
    public var weakContrast: Float = AnchorFinder.weakContrast

    public init() {}
}

/// One seal's reading in a copy, as the sweep needs it.
public struct SealScore: Codable, Sendable {
    public var seal: Int
    public var inliers: Int
    public var retraced: Int
    public var possible: Int
    public var coverage: Double
    public var scale: Double
}

public struct SealAcceptanceRow: Codable, Sendable {
    public var picture: Int
    public var path: String
    /// Nil for a picture never sealed.
    public var sealed: Bool
    public var change: String
    public var width: Int
    public var height: Int
    public var anchors: Int
    public var own: SealScore?
    /// Every other seal with at least 6 inliers.
    public var others: [SealScore]
    /// Of the seal's anchors the fitted transform puts inside the copy, how many the copy holds again.
    public var held: Int
    public var inside: Int
    public var seconds: Double
}

/// Per change: anchors held again and the bits that flipped between a held anchor and its partner.
public struct SealFlips: Codable, Sendable {
    public var pairs = 0
    public var flips = [Int](repeating: 0, count: 256)
}

public struct SealAcceptanceReport: Codable, Sendable {
    public struct Rate: Codable, Sendable {
        public var change: String
        public var group: String
        public var found: Int
        public var tried: Int
        public var bar: Double?
        public var rate: Double { tried > 0 ? Double(found) / Double(tried) : 0 }
    }

    public struct Point: Codable, Sendable {
        public var inliers: Int
        public var hops: Int
        public var falseMatches: Int
        public var classI: Double
        public var combined: Double
        public var filters: Double
        public var recapture: Double
    }

    public var settings: SealAcceptanceSettings
    public var pictures: Int
    public var nullPictures: Int
    public var rates: [Rate]
    public var groups: [Rate]
    public var falseMatches: Int
    public var falseFromNull: Int
    public var passed: Bool
    public var failing: [String]
    /// The thresholds swept: the fewest inliers and hops with no false match, and what each finds.
    public var sweep: [Point]
    public var flips: [String: SealFlips]
    public var repeatability: [String: Double]
    public var seconds: Double
}

public enum SealAcceptance {
    /// decision-155's bars.
    public static func bar(_ group: SealChange.Group) -> Double {
        switch group {
        case .classI: return 0.95
        case .combined: return 0.90
        case .filters: return 0.80
        case .recapture: return 0.60
        }
    }

    /// The picture as shared: oriented and at most `longSide` px on its long side.
    public static func picture(_ url: URL, longSide: Int) throws -> SealPixels {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw VeilGardeFailure.data("cannot read \(url.path)") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide, kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw VeilGardeFailure.data("cannot decode \(url.path)")
        }
        return try SealPixels(cg)
    }

    static func seed(_ base: UInt64, picture: Int, change: SealChange) -> UInt64 {
        var rng = SplitMix64(seed: base ^ (UInt64(picture + 1) &* 0x9E37_79B9_7F4A_7C15))
        let index = UInt64(SealChange.allCases.firstIndex(of: change) ?? 0)
        return rng.next() ^ (index &* 0xBF58_476D_1CE4_E5B9)
    }

    /// Runs the acceptance: seals `sealed`, detects every change of them and of `null`, appends each row to `rows`.
    public static func run(sealed: [AcceptanceSample.Item], null: [AcceptanceSample.Item], settings: SealAcceptanceSettings,
                           key: SealKey = .default, rows rowsURL: URL?, log: @escaping @Sendable (String) -> Void) throws -> SealAcceptanceReport {
        let start = Date()
        guard let measure = NeighbourhoodMeasures.named(settings.measure, key: key) else {
            throw VeilGardeFailure.usage("no measure \(settings.measure): \(NeighbourhoodMeasures.names.joined(separator: ", "))")
        }
        let lock = NSLock()
        AnchorFinder.weakContrast = settings.weakContrast

        // Seal every picture, in parallel.
        var records = [SealRecord?](repeating: nil, count: sealed.count)
        var failures = [String](repeating: "", count: sealed.count)
        DispatchQueue.concurrentPerform(iterations: sealed.count) { i in
            do {
                let p = try picture(sealed[i].url, longSide: settings.longSide)
                let reading = try AnchorReading.read(try p.cgImage(), key: key, measures: [measure], count: AnchorReading.sealCount, residual: false,
                                                     selection: settings.selection)[0]
                let facts = SealImageFacts(width: p.width, height: p.height, sha256: ContentHash.sha256Hex(Data(p.rgb)), name: sealed[i].url.lastPathComponent)
                let r = try SealRecord(id: nil, label: "\(i)", keyFingerprint: key.fingerprint, measure: measure.name, image: facts,
                                       anchors: reading.anchors, paths: PathWalker.walk(reading.anchors, pointerBits: measure.pointerBits), interlace: nil)
                lock.lock()
                records[i] = r
                lock.unlock()
            } catch {
                lock.lock()
                failures[i] = "\(error)"
                lock.unlock()
            }
        }
        let kept = records.compactMap { $0 }
        let index = Dictionary(uniqueKeysWithValues: records.enumerated().compactMap { i, r in r.map { (i, $0) } })
        log(String(format: "sealed %d of %d pictures in %.0f s (%d failed)", kept.count, sealed.count, Date().timeIntervalSince(start),
                   failures.filter { !$0.isEmpty }.count))
        let order = records.indices.filter { records[$0] != nil }

        if let rowsURL {
            FileManager.default.createFile(atPath: rowsURL.path, contents: nil)
        }
        let writer = rowsURL.flatMap { try? FileHandle(forWritingTo: $0) }
        var rows: [SealAcceptanceRow] = []
        var flips: [String: SealFlips] = [:]
        var done = 0
        let jobs: [(item: AcceptanceSample.Item, picture: Int, sealed: Bool)] =
            order.map { (sealed[$0], $0, true) } + null.enumerated().map { (item: $0.element, picture: sealed.count + $0.offset, sealed: false) }
        let total = jobs.count

        DispatchQueue.concurrentPerform(iterations: jobs.count) { j in
            let job = jobs[j]
            guard let p = try? picture(job.item.url, longSide: settings.longSide) else { return }
            var mine: [SealAcceptanceRow] = []
            var myFlips: [String: SealFlips] = [:]
            for change in settings.changes {
                let t0 = Date()
                guard let copy = try? change.apply(p, seed: seed(settings.seed, picture: job.picture, change: change)),
                      let cg = try? copy.cgImage(),
                      let reading = try? AnchorReading.read(cg, key: key, measures: [measure], count: AnchorReading.searchCount, residual: false,
                                                       selection: settings.selection)[0]
                else { continue }
                var own: SealScore?
                var others: [SealScore] = []
                var held = 0, inside = 0
                for (n, record) in kept.enumerated() {
                    let picture = order[n]
                    guard let m = SealSearch.score(record, in: reading, pointerBits: measure.pointerBits) else { continue }
                    let score = SealScore(seal: picture, inliers: m.inliers, retraced: m.retraced, possible: m.possible, coverage: m.coverage, scale: m.scale)
                    if job.sealed, picture == job.picture {
                        own = score
                        if m.found || m.inliers >= 8 {
                            let h = holdings(record, reading, m.transform, into: &myFlips[change.rawValue, default: SealFlips()])
                            held = h.held
                            inside = h.inside
                        }
                    } else if m.inliers >= 6 {
                        others.append(score)
                    }
                }
                if job.sealed, own == nil { own = SealScore(seal: job.picture, inliers: 0, retraced: 0, possible: 0, coverage: 0, scale: 0) }
                mine.append(SealAcceptanceRow(picture: job.picture, path: job.item.url.lastPathComponent, sealed: job.sealed, change: change.rawValue,
                                              width: copy.width, height: copy.height, anchors: reading.anchors.count, own: own, others: others,
                                              held: held, inside: inside, seconds: Date().timeIntervalSince(t0)))
            }
            lock.lock()
            rows += mine
            for (k, f) in myFlips {
                var all = flips[k, default: SealFlips()]
                all.pairs += f.pairs
                for b in 0..<256 { all.flips[b] += f.flips[b] }
                flips[k] = all
            }
            if let writer {
                for row in mine { if let line = try? JSONEncoder().encode(row) { writer.write(line + Data("\n".utf8)) } }
            }
            done += 1
            let found = mine.filter { $0.sealed && passes($0.own, settings.foundInliers, settings.foundHops) }.count
            log("\(done)/\(total) \(job.sealed ? "sealed" : "null  ") \(job.item.url.lastPathComponent): \(job.sealed ? "\(found)/\(mine.count) found" : "\(mine.filter { !$0.others.allSatisfy { !passes($0, settings.foundInliers, settings.foundHops) } }.count) false")")
            lock.unlock()
        }
        try? writer?.close()
        var report = summarize(rows, settings: settings)
        report.flips = flips
        report.seconds = Date().timeIntervalSince(start)
        _ = index
        return report
    }

    static func passes(_ s: SealScore?, _ inliers: Int, _ hops: Int) -> Bool {
        guard let s else { return false }
        return s.inliers >= inliers && s.retraced >= hops
    }

    /// The seal's anchors the transform puts inside the copy, how many the copy holds again (within max(3, σ/2), scale within 1.5×),
    /// and the bits that flipped between each held anchor and its partner.
    static func holdings(_ record: SealRecord, _ reading: AnchorReading, _ m: SealTransform, into flips: inout SealFlips) -> (held: Int, inside: Int) {
        let cell = 16.0
        var grid = [Int: [Int]]()
        for (i, a) in reading.anchors.enumerated() { grid[Int(Double(a.x) / cell) * 100_000 + Int(Double(a.y) / cell), default: []].append(i) }
        var held = 0, inside = 0
        for a in record.anchors {
            let (x, y) = m.apply(Double(a.x), Double(a.y))
            guard x >= 0, y >= 0, x < Double(reading.width), y < Double(reading.height) else { continue }
            inside += 1
            let s = Double(a.scale) * m.scale(at: Double(a.x), Double(a.y))
            let reach = max(3, s / 2)
            var best: (Int, Double)?
            let gx = Int(x / cell), gy = Int(y / cell), span = Int((reach / cell).rounded(.up))
            for cx in (gx - span)...(gx + span) {
                for cy in (gy - span)...(gy + span) {
                    for i in grid[cx * 100_000 + cy] ?? [] {
                        let b = reading.anchors[i]
                        let d = hypot(Double(b.x) - x, Double(b.y) - y), ratio = Double(b.scale) / s
                        guard d <= reach, ratio < 1.5, ratio > 1 / 1.5 else { continue }
                        if best == nil || d < best!.1 { best = (i, d) }
                    }
                }
            }
            guard let (i, _) = best else { continue }
            held += 1
            flips.pairs += 1
            let c = a.code, q = reading.anchors[i].code
            for b in 0..<256 where c.bit(b) != q.bit(b) { flips.flips[b] += 1 }
        }
        return (held, inside)
    }

    public static func summarize(_ rows: [SealAcceptanceRow], settings: SealAcceptanceSettings) -> SealAcceptanceReport {
        func found(_ row: SealAcceptanceRow, _ i: Int, _ h: Int) -> Bool {
            guard row.sealed, let own = row.own, passes(own, i, h) else { return false }
            return !row.others.contains { passes($0, i, h) && ($0.inliers, $0.retraced) > (own.inliers, own.retraced) }
        }
        func falseMatch(_ row: SealAcceptanceRow, _ i: Int, _ h: Int) -> Bool { row.others.contains { passes($0, i, h) } }
        let byChange = Dictionary(grouping: rows.filter(\.sealed), by: \.change)
        func rates(_ i: Int, _ h: Int) -> [SealAcceptanceReport.Rate] {
            settings.changes.map { c in
                let rs = byChange[c.rawValue] ?? []
                return .init(change: c.rawValue, group: c.group.rawValue, found: rs.filter { found($0, i, h) }.count, tried: rs.count,
                             bar: c.group == .filters ? nil : bar(c.group))
            }
        }
        func groups(_ rates: [SealAcceptanceReport.Rate]) -> [SealAcceptanceReport.Rate] {
            [SealChange.Group.classI, .combined, .filters, .recapture].map { g in
                let rs = rates.filter { $0.group == g.rawValue }
                return .init(change: g.rawValue, group: g.rawValue, found: rs.map(\.found).reduce(0, +), tried: rs.map(\.tried).reduce(0, +), bar: bar(g))
            }
        }
        let i0 = settings.foundInliers, h0 = settings.foundHops
        let r = rates(i0, h0), g = groups(r)
        let falseAll = rows.filter { falseMatch($0, i0, h0) }.count
        let falseNull = rows.filter { !$0.sealed && falseMatch($0, i0, h0) }.count
        var failing: [String] = []
        for rate in r where rate.bar != nil && rate.rate < rate.bar! { failing.append("\(rate.change) \(Int((rate.rate * 100).rounded()))% < \(Int(rate.bar! * 100))%") }
        for grp in g where grp.group == "filters" || grp.group == "recapture" {
            if grp.rate < grp.bar! { failing.append("\(grp.change) \(Int((grp.rate * 100).rounded()))% < \(Int(grp.bar! * 100))%") }
        }
        if falseAll > 0 { failing.append("\(falseAll) false matches (\(falseNull) in the null)") }

        var sweep: [SealAcceptanceReport.Point] = []
        for h in 0...24 {
            guard let i = (6...80).first(where: { i in !rows.contains { falseMatch($0, i, h) } }) else { continue }
            let gg = groups(rates(i, h))
            sweep.append(.init(inliers: i, hops: h, falseMatches: 0, classI: gg[0].rate, combined: gg[1].rate, filters: gg[2].rate, recapture: gg[3].rate))
        }
        var repeatability: [String: Double] = [:]
        for (c, rs) in byChange {
            let held = rs.map(\.held).reduce(0, +), inside = rs.map(\.inside).reduce(0, +)
            repeatability[c] = inside > 0 ? Double(held) / Double(inside) : 0
        }
        return SealAcceptanceReport(settings: settings, pictures: Set(rows.filter(\.sealed).map(\.picture)).count,
                                    nullPictures: Set(rows.filter { !$0.sealed }.map(\.picture)).count, rates: r, groups: g,
                                    falseMatches: falseAll, falseFromNull: falseNull, passed: failing.isEmpty, failing: failing, sweep: sweep,
                                    flips: [:], repeatability: repeatability, seconds: 0)
    }
}
