//
//  Agreement.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The flywheel's north-star number: how often the base (the fusion head alone) reaches the
//        same call as the pooled verdict (base and heads through the combiner), overall and per
//        domain, and how accurate each is. The flywheel's job is to make the base trustworthy on
//        more images, so the agreement should climb and the AUC gap close.
//  PIN:  flywheel_agreement.py's formula on the store instead of the v197 fusion cache: every row that
//        is not golden or NSFW and carries both embeddings; pooled = StackCombiner.pool (the
//        detector's arithmetic) on the bundle's art, blur and human heads and the art-pair head,
//        for every row, capture-present ones included, as the Python formula computes it;
//        agreement = mean((base > 0.5) == (pooled > 0.5)); domains by v198_probe.domain_of's path
//        rule; accuracy on a fixed 20% (StableSplit "agreement:v1" on the id). A row of the
//        report appends to flywheel_metrics.csv with the Python report's columns.
//

import Foundation
import VeilGardeCore

public struct AgreementReport: Codable, Sendable, Equatable {
    public var bundle: String
    public var rows: Int
    public var camera: Int
    public var processed: Int
    public var agreementAll: Double
    public var agreementCamera: Double?
    public var agreementProcessed: Double?
    public var testRows: Int
    public var baseAUC: Double
    public var weightedAUC: Double
    public var aucGap: Double
    public var baseRealFPR: Double
    public var baseGenFNR: Double
    public var weightedRealFPR: Double
    public var weightedGenFNR: Double
}

public enum Agreement {
    /// v198_probe.domain_of.
    public static func domain(_ path: String) -> String {
        let p = path.lowercased()
        if p.contains("/atlas/") || p.contains("reel_screenshots") || p.contains("_shot") || p.contains("midjourney") || p.contains("ig_fullres") { return "processed" }
        if p.contains("final_mixed") || p.contains("iphone") || p.contains("macro") || p.contains("photoreal_faces") { return "camera" }
        return "other"
    }

    public static func measure(_ bundle: ModelBundle, store: FeatureStore, label: String) throws -> AgreementReport {
        guard let fusionURL = bundle.url(.fusionHead), let combinerURL = bundle.url(.combiner) else {
            throw VeilGardeFailure.missing("the bundle needs a fusion head and a combiner")
        }
        let fusion = try GBDTModel.load(fusionURL)
        let combiner = try StackCombiner.load(combinerURL)
        let heads = try [HeadKind.art, .blur, .human].map { kind -> LinearHead in
            guard let url = bundle.url(.head, head: kind) else { throw VeilGardeFailure.missing("the bundle has no \(kind.rawValue) head") }
            return try LinearHead.load(url)
        }
        let pair = try bundle.url(.head, head: .artPair).map { try LinearHead.load($0) }
        let s = try store.select(columns: Set(FeatureColumn.allCases)) { !$0.golden && !$0.nsfw }
        let keep = (0..<s.count).filter { s.vector(.dinoNorm, row: $0).first?.isFinite == true && s.vector(.dinoFusion, row: $0).first?.isFinite == true }
        var base = [Float](repeating: 0, count: keep.count), pooled = [Float](repeating: 0, count: keep.count)
        base.withUnsafeMutableBufferPointer { b in
            pooled.withUnsafeMutableBufferPointer { w in
                DispatchQueue.concurrentPerform(iterations: (keep.count + 1023) / 1024) { c in
                    for k in (c * 1024)..<min(keep.count, (c + 1) * 1024) {
                        let i = keep[k]
                        var row = [Float]()
                        row.reserveCapacity(FusionVector.count)
                        for column in FeatureColumn.fusion { row.append(contentsOf: s.vector(column, row: i)) }
                        let norm = Array(s.vector(.dinoNorm, row: i))
                        let p = fusion.predict(row)
                        b[k] = p
                        w[k] = combiner.pool(base: p, heads: heads.map { $0.pAI(norm) }, pairAI: pair?.pAI(norm))
                    }
                }
            }
        }
        let labels = keep.map { Float(s.rows[$0].label) }
        let domains = keep.map { domain(s.rows[$0].path) }
        func agreement(_ where: (Int) -> Bool) -> Double? {
            let idx = keep.indices.filter(`where`)
            guard !idx.isEmpty else { return nil }
            return Double(idx.filter { (base[$0] > 0.5) == (pooled[$0] > 0.5) }.count) / Double(idx.count)
        }
        let test = keep.indices.filter { StableSplit.isHoldout(s.rows[keep[$0]].id, salt: "agreement:v1", fraction: 0.2) }
        func rate(_ p: [Float], real: Bool) -> Double {
            let idx = test.filter { (labels[$0] == 0) == real }
            guard !idx.isEmpty else { return .nan }
            return Double(idx.filter { real ? p[$0] > 0.5 : p[$0] < 0.5 }.count) / Double(idx.count)
        }
        let baseAUC = Metrics.auc(test.map { base[$0] }, test.map { labels[$0] })
        let weightedAUC = Metrics.auc(test.map { pooled[$0] }, test.map { labels[$0] })
        return AgreementReport(bundle: label, rows: keep.count, camera: domains.filter { $0 == "camera" }.count,
                               processed: domains.filter { $0 == "processed" }.count, agreementAll: agreement { _ in true } ?? .nan,
                               agreementCamera: agreement { domains[$0] == "camera" }, agreementProcessed: agreement { domains[$0] == "processed" },
                               testRows: test.count, baseAUC: baseAUC, weightedAUC: weightedAUC, aucGap: weightedAUC - baseAUC,
                               baseRealFPR: rate(base, real: true), baseGenFNR: rate(base, real: false),
                               weightedRealFPR: rate(pooled, real: true), weightedGenFNR: rate(pooled, real: false))
    }

    /// Appends one row with flywheel_agreement.py's columns.
    public static func append(_ r: AgreementReport, to csv: URL, date: Date = Date()) throws {
        let fm = FileManager.default
        let header = "date,fusion,corpus_n,agreement_all,agreement_camera,agreement_processed,base_auc,weighted_auc,auc_gap,base_real_fpr,base_gen_fnr\n"
        if !fm.fileExists(atPath: csv.path) {
            try fm.createDirectory(at: csv.deletingLastPathComponent(), withIntermediateDirectories: true)
            try header.write(to: csv, atomically: true, encoding: .utf8)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        func n(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "" }
        let line = [f.string(from: date), r.bundle, String(r.rows), n(r.agreementAll), n(r.agreementCamera), n(r.agreementProcessed),
                    n(r.baseAUC), n(r.weightedAUC), n(r.aucGap), n(r.baseRealFPR), n(r.baseGenFNR)].joined(separator: ",") + "\n"
        let handle = try FileHandle(forWritingTo: csv)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }
}
