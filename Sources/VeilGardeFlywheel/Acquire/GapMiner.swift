//
//  GapMiner.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Where the next acquisition should look: the store's rows bucketed by (domain, category,
//        label), each bucket's camera error (the camera head's call against the truth) plus its
//        disagreement with the pooled verdict, ranked, and the worst buckets mapped to the
//        collector jobs that fill them.
//  PIN:  flywheel_gap.py on the store: domains by v198_probe.domain_of (acquired rows count as
//        processed, as the API pools did), categories from the row or, where the row's category
//        is not one of the five, from its path as cat_of reads it; buckets need 20 rows;
//        gap = error + disagreement, sorted stably from the largest; buckets at gap ≥ 0.05 emit
//        their TARGET_MAP jobs once each, in rank order.
//

import Foundation
import VeilGardeCore

public struct GapBucket: Codable, Sendable, Equatable {
    public var domain: String
    public var category: String
    public var label: Int
    public var n: Int
    public var cameraError: Double
    public var disagreement: Double
    public var gap: Double

    public var name: String { "\(domain)/\(category)/\(label == 1 ? "gen" : "real")" }
}

public struct GapReport: Codable, Sendable {
    public var generated: String
    public var buckets: [GapBucket]
    public var jobs: [AcquireJob]

    public var table: String {
        func pad(_ s: String, _ n: Int, right: Bool = true) -> String { s.count >= n ? s : (right ? String(repeating: " ", count: n - s.count) + s : s + String(repeating: " ", count: n - s.count)) }
        var lines = [pad("bucket", 26, right: false) + pad("n", 6) + pad("cam_err", 10) + pad("disagree", 10) + pad("gap", 8)]
        for b in buckets {
            lines.append(pad(b.name, 26, right: false) + pad(String(b.n), 6) + pad(String(format: "%.1f%%", b.cameraError * 100), 10)
                         + pad(String(format: "%.1f%%", b.disagreement * 100), 10) + pad(String(format: "%.2f", b.gap), 8))
        }
        return lines.joined(separator: "\n")
    }
}

public enum GapMiner {
    public static let categories = ["photo", "human", "art", "blur", "cgi"]

    public static func domain(_ row: FeatureRow) -> String {
        row.path.hasPrefix("/acquired/") ? "processed" : Agreement.domain(row.path)
    }

    /// The row's category among the five, or cat_of(path).
    public static func category(_ row: FeatureRow) -> String {
        if categories.contains(row.category) { return row.category }
        for k in ["art", "blur", "human", "cgi", "photo"] where row.path.contains("/\(k)/") { return k }
        return (row.path.contains("final_mixed") || row.path.contains("iphone")) ? "photo" : "other"
    }

    public static func mine(_ bundle: ModelBundle, store: FeatureStore, shards: [String]? = nil, targets: AcquireTargets) throws -> GapReport {
        let s = try store.select(columns: Set(FeatureColumn.allCases), shards: shards) { !$0.golden && !$0.nsfw }
        let keep = (0..<s.count).filter { s.vector(.dinoNorm, row: $0).first?.isFinite == true && s.vector(.dinoFusion, row: $0).first?.isFinite == true }
        let (camera, pooled) = try StoreScoring.scores(bundle, s, rows: keep)
        var buckets: [GapBucket] = []
        for d in ["camera", "processed"] {
            for c in categories {
                for l in [0, 1] {
                    let idx = keep.indices.filter { k in
                        let r = s.rows[keep[k]]
                        return r.label == l && domain(r) == d && category(r) == c
                    }
                    guard idx.count >= 20 else { continue }
                    let err = Double(idx.filter { (camera[$0] > 0.5 ? 1 : 0) != l }.count) / Double(idx.count)
                    let dis = Double(idx.filter { (camera[$0] > 0.5) != (pooled[$0] > 0.5) }.count) / Double(idx.count)
                    buckets.append(GapBucket(domain: d, category: c, label: l, n: idx.count, cameraError: err, disagreement: dis, gap: err + dis))
                }
            }
        }
        buckets = buckets.enumerated().sorted { ($0.element.gap, -$0.offset) > ($1.element.gap, -$1.offset) }.map(\.element)
        var jobs: [AcquireJob] = []
        for b in buckets where b.gap >= 0.05 {
            for var job in targets.jobs(domain: b.domain, category: b.category, label: b.label)
            where !jobs.contains(where: { ($0.source, $0.category, $0.label, $0.query) == (job.source, job.category, job.label, job.query) }) {
                job.gap = (b.gap * 1000).rounded() / 1000
                jobs.append(job)
            }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return GapReport(generated: f.string(from: Date()), buckets: buckets, jobs: jobs)
    }
}
