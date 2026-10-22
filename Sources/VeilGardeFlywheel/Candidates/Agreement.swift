//
//  Agreement.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The flywheel's north-star number: how often the camera member alone reaches the same call
//        as the combiner's pooled verdict (the camera head and the evidence members through the
//        stack combiner), overall and per domain, and how accurate each is. The flywheel's job is
//        to make the camera head trustworthy on more images, so the agreement should climb and the
//        AUC gap close.
//  PIN:  flywheel_agreement.py's formula on the store: every row that is not golden or NSFW and
//        carries both embeddings; pooled = StackCombiner.pool (the combiner revision's arithmetic,
//        the camera member as the anchor) on the evidence members the bundle's combiner names, for
//        every row, capture-present ones included, as the Python formula computes it;
//        agreement = mean((camera > 0.5) == (pooled > 0.5)); domains by v198_probe.domain_of's path
//        rule; accuracy on a fixed 20% (StableSplit "agreement:v1" on the id). A row of the report
//        appends to flywheel_metrics.csv.
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
    public var cameraAUC: Double
    public var pooledAUC: Double
    public var aucGap: Double
    public var cameraRealFPR: Double
    public var cameraGenFNR: Double
    public var pooledRealFPR: Double
    public var pooledGenFNR: Double
}

/// The camera head's P(AI) and the pooled P(AI) on store rows, as the combiner revision computes
/// them with the camera member as the anchor (a store row has no screenshot gate) and each evidence
/// member the bundle's combiner names read through its linear head on dino_norm.
public enum StoreScoring {
    public static func scores(_ bundle: ModelBundle, _ s: StoreSelection, rows keep: [Int]) throws -> (camera: [Float], pooled: [Float]) {
        guard let cameraURL = bundle.url(.camera), let combinerURL = bundle.url(.combiner) else {
            throw VeilGardeFailure.missing("the bundle needs a camera head and a combiner")
        }
        let camera = try GBDTModel.load(cameraURL)
        guard camera.featureCount == CameraRow.width else { throw VeilGardeFailure.data("the camera head reads \(camera.featureCount) features, not \(CameraRow.width)") }
        let combiner = try StackCombiner.load(combinerURL)
        let heads = try combiner.evidenceMembers.map { member -> LinearHead in
            guard let kind = HeadKind(rawValue: member), let url = bundle.url(.head, head: kind) else {
                throw VeilGardeFailure.missing("the combiner pools the \(member) member, which has no head in the bundle")
            }
            return try LinearHead.load(url)
        }
        var cam = [Float](repeating: 0, count: keep.count), pooled = [Float](repeating: 0, count: keep.count)
        cam.withUnsafeMutableBufferPointer { c in
            pooled.withUnsafeMutableBufferPointer { w in
                DispatchQueue.concurrentPerform(iterations: (keep.count + 1023) / 1024) { chunk in
                    for k in (chunk * 1024)..<min(keep.count, (chunk + 1) * 1024) {
                        let i = keep[k]
                        var row = [Float]()
                        row.reserveCapacity(CameraRow.width)
                        for column in CameraRow.columns { row.append(contentsOf: s.vector(column, row: i)) }
                        let norm = Array(s.vector(.dinoNorm, row: i))
                        let p = camera.predict(row)
                        c[k] = p
                        w[k] = combiner.pool(anchor: p, evidence: heads.map { $0.pAI(norm) })
                    }
                }
            }
        }
        return (cam, pooled)
    }
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
        let s = try store.select(columns: Set(FeatureColumn.allCases)) { !$0.golden && !$0.nsfw }
        let keep = (0..<s.count).filter { s.vector(.dinoNorm, row: $0).first?.isFinite == true && s.vector(.dinoFusion, row: $0).first?.isFinite == true }
        let (camera, pooled) = try StoreScoring.scores(bundle, s, rows: keep)
        let labels = keep.map { Float(s.rows[$0].label) }
        let domains = keep.map { domain(s.rows[$0].path) }
        func agreement(_ where: (Int) -> Bool) -> Double? {
            let idx = keep.indices.filter(`where`)
            guard !idx.isEmpty else { return nil }
            return Double(idx.filter { (camera[$0] > 0.5) == (pooled[$0] > 0.5) }.count) / Double(idx.count)
        }
        let test = keep.indices.filter { StableSplit.isHoldout(s.rows[keep[$0]].id, salt: "agreement:v1", fraction: 0.2) }
        func rate(_ p: [Float], real: Bool) -> Double {
            let idx = test.filter { (labels[$0] == 0) == real }
            guard !idx.isEmpty else { return .nan }
            return Double(idx.filter { real ? p[$0] > 0.5 : p[$0] < 0.5 }.count) / Double(idx.count)
        }
        let cameraAUC = Metrics.auc(test.map { camera[$0] }, test.map { labels[$0] })
        let pooledAUC = Metrics.auc(test.map { pooled[$0] }, test.map { labels[$0] })
        return AgreementReport(bundle: label, rows: keep.count, camera: domains.filter { $0 == "camera" }.count,
                               processed: domains.filter { $0 == "processed" }.count, agreementAll: agreement { _ in true } ?? .nan,
                               agreementCamera: agreement { domains[$0] == "camera" }, agreementProcessed: agreement { domains[$0] == "processed" },
                               testRows: test.count, cameraAUC: cameraAUC, pooledAUC: pooledAUC, aucGap: pooledAUC - cameraAUC,
                               cameraRealFPR: rate(camera, real: true), cameraGenFNR: rate(camera, real: false),
                               pooledRealFPR: rate(pooled, real: true), pooledGenFNR: rate(pooled, real: false))
    }

    /// Appends one row: the bundle, the corpus size, the agreements, both AUCs and the camera head's error rates.
    public static func append(_ r: AgreementReport, to csv: URL, date: Date = Date()) throws {
        let fm = FileManager.default
        let header = "date,bundle,corpus_n,agreement_all,agreement_camera,agreement_processed,camera_auc,pooled_auc,auc_gap,camera_real_fpr,camera_gen_fnr\n"
        if !fm.fileExists(atPath: csv.path) {
            try fm.createDirectory(at: csv.deletingLastPathComponent(), withIntermediateDirectories: true)
            try header.write(to: csv, atomically: true, encoding: .utf8)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        func n(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "" }
        let line = [f.string(from: date), r.bundle, String(r.rows), n(r.agreementAll), n(r.agreementCamera), n(r.agreementProcessed),
                    n(r.cameraAUC), n(r.pooledAUC), n(r.aucGap), n(r.cameraRealFPR), n(r.cameraGenFNR)].joined(separator: ",") + "\n"
        let handle = try FileHandle(forWritingTo: csv)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }
}
