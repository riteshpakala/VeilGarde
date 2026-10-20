//
//  ZoomEscalation.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Zoom escalation (v3.2), DISABLED by default since 2026-07-19: on a capture-absent image
//        where the semantic vote is ≥ 0.90 generated against a real weighted verdict, rule out the
//        two style-overlap families (noiseprint P(camera) ≥ 0.5, cgi render head ≥ 0.5), then ask
//        the frozen fusion reference at zoom; a max crop ≥ 0.70 with two crops ≥ 0.60 revises the
//        verdict. Every armed escalation is logged (JSONL) as a drift signal.
//  PIN:  Garde's zoom block and logEscalation. Its motivating anchor (the lion) was provenance-
//        adjudicated REAL (Atif Saeed 2015, TinEye): 1 confirmed false positive, 0 true positives,
//        and the arming class measured 97% real on reviewed X data (the research record, quoted). Kept only for
//        recalibration against confirmed true positives. Telemetry never affects a result; opt
//        out with VEILGARDE_NO_TELEMETRY=1, redirect with VEILGARDE_TELEMETRY_DIR.
//

import CoreGraphics
import Foundation

enum ZoomEscalation {
    static func apply(_ chain: inout SemanticChain.Probe, _ state: inout RouteState, _ s: DetectionSignals, capture cap: CaptureSignature,
                      semanticMajority: Float, renderArbiterP: Float?, canDecide: Bool) {
        guard s.config.mechanisms.zoomEscalation, !cap.present, semanticMajority >= 0.90, chain.verdict == "real" else { return }
        state.semanticTriggered = true
        let pCam = NoiseprintLens.score(s.cgImage) ?? 0.5
        let cgiP = renderArbiterP ?? 1.0
        if pCam < 0.5, cgiP < 0.5 {
            let ev = FusionReference.zoomCropEvidence(s.cgImage, config: s.config)
            let decisive = ev.map { $0.maxP >= 0.70 && $0.corroborating >= 2 } ?? false
            state.stack.append(SpecialistContribution(name: "zoom-escalation", pAI: ev?.maxP ?? 0.5, verdict: decisive ? "generated" : "unconfirmed",
                                                      weight: canDecide ? (decisive ? 1.0 : 0.25) : 0.0))
            if decisive, let ev {
                chain.decisive = true
                chain.verdict = "generated"
                chain.p = max(chain.p, ev.maxP)
            }
            log(sem: semanticMajority, pCam: pCam, cgiP: cgiP, maxP: ev?.maxP, corroborating: ev?.corroborating, decisive: canDecide && decisive)
        } else {
            log(sem: semanticMajority, pCam: pCam, cgiP: cgiP, maxP: nil, corroborating: nil, decisive: false)
        }
    }

    /// One armed escalation, appended to escalation_log.jsonl, best effort.
    static func log(sem: Float, pCam: Float, cgiP: Float, maxP: Float?, corroborating: Int?, decisive: Bool) {
        let env = ProcessInfo.processInfo.environment
        if env["VEILGARDE_NO_TELEMETRY"] == "1" { return }
        let dir: URL
        if let d = env["VEILGARDE_TELEMETRY_DIR"] {
            dir = URL(fileURLWithPath: d)
        } else {
            guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
            dir = support.appendingPathComponent("VeilGarde", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("escalation_log.jsonl")
        var row: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "sem": Double(sem), "p_cam": Double(pCam), "cgi_p": Double(cgiP), "decisive": decisive]
        if let m = maxP { row["max_p"] = Double(m) }
        if let c = corroborating { row["corroborating"] = c }
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: file) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try? (line + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
