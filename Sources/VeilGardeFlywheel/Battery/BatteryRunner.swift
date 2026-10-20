//
//  BatteryRunner.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The battery: every resolved image through a verdict source, per-group accuracy, each
//        group judged by its mode against the recorded floors, one PASS or FAIL for the whole.
//  PIN:  The Python battery runner's run_full, verbatim in its rules. Per image: the input hashed before and
//        after (bytes that change mid-run are an error); weighted correct when the prediction is
//        the group's want; semantic correct when (majority > 0.5) == (want is generated), counted
//        only where tiles exist. Per group: acc = ok / max(n, 1), sem_acc = semok / semn or nil.
//        HARD needs acc 1.0; HARD_SEM also sem_acc 1.0 (a missing one fails); RATCHET needs
//        acc ≥ floor − tolerance when a floor is recorded, RATCHET_SEM also the semantic floor;
//        TAXONOMY and REPORT never gate; an incomplete group fails. A ratcheted group whose globs
//        find no image scores 0 and fails, as in the Python runner; its status says "FAIL(no images)". The whole passes only with no
//        backend errors and a baseline present (or a rebaseline asked for).
//

import Foundation
import VeilGardeCore

public struct BatteryGroupResult: Codable, Sendable, Equatable {
    public var acc: Double
    public var n: Int
    public var expectedN: Int?
    public var inputComplete: Bool?
    public var semAcc: Double?
    public var mode: BatterySpec.Mode
    public var want: String

    public init(acc: Double, n: Int, expectedN: Int? = nil, inputComplete: Bool? = nil, semAcc: Double? = nil, mode: BatterySpec.Mode, want: String) {
        self.acc = acc
        self.n = n
        self.expectedN = expectedN
        self.inputComplete = inputComplete
        self.semAcc = semAcc
        self.mode = mode
        self.want = want
    }

    enum CodingKeys: String, CodingKey {
        case acc, n, mode, want
        case expectedN = "expected_n"
        case inputComplete = "input_complete"
        case semAcc = "sem_acc"
    }

    /// Encodes `sem_acc: null` when absent, as Python's json.dumps does.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(acc, forKey: .acc)
        try c.encode(n, forKey: .n)
        try c.encodeIfPresent(expectedN, forKey: .expectedN)
        try c.encodeIfPresent(inputComplete, forKey: .inputComplete)
        if let semAcc { try c.encode(semAcc, forKey: .semAcc) } else { try c.encodeNil(forKey: .semAcc) }
        try c.encode(mode, forKey: .mode)
        try c.encode(want, forKey: .want)
    }
}

public struct BatteryImageRow: Codable, Sendable, Equatable {
    public var path: String
    public var inputSHA256: String
    public var group: String
    public var want: String
    public var weightedPred: String
    public var weightedP: Double
    public var semScore: Double?
    public var capPresent: Bool

    enum CodingKeys: String, CodingKey {
        case path, group, want
        case inputSHA256 = "input_sha256"
        case weightedPred = "weighted_pred"
        case weightedP = "weighted_p"
        case semScore = "sem_score"
        case capPresent = "cap_present"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(inputSHA256, forKey: .inputSHA256)
        try c.encode(group, forKey: .group)
        try c.encode(want, forKey: .want)
        try c.encode(weightedPred, forKey: .weightedPred)
        try c.encode(weightedP, forKey: .weightedP)
        if let semScore { try c.encode(semScore, forKey: .semScore) } else { try c.encodeNil(forKey: .semScore) }
        try c.encode(capPresent, forKey: .capPresent)
    }
}

public struct BatteryReport: Codable, Sendable {
    public struct Status: Codable, Sendable, Equatable { public var group: String; public var status: String; public var floor: Double? }
    public struct BackendError: Codable, Sendable, Equatable { public var path: String; public var group: String; public var error: String }
    public struct FileHash: Codable, Sendable, Equatable { public var path: String; public var sha256: String? }
    public struct BaselineHashes: Codable, Sendable, Equatable {
        public var path: String
        public var sha256Before: String?
        public var sha256After: String?
        public var changed: Bool
        enum CodingKeys: String, CodingKey { case path, changed; case sha256Before = "sha256_before"; case sha256After = "sha256_after" }
    }

    public var backend: String
    public var gate: BatterySpec.Gate
    public var pass: Bool
    public var rebaseline: Bool
    public var resolvedVars: [String: String]
    public var spec: FileHash
    public var baseline: BaselineHashes
    public var runtime: [String: String]
    public var inputSetSHA256: String
    public var backendErrors: [BackendError]
    public var groups: [String: BatteryGroupResult]
    /// The groups in spec order, with their statuses as printed.
    public var statuses: [Status]
    public var images: [BatteryImageRow]
    public var date: Date

    enum CodingKeys: String, CodingKey {
        case backend, gate, pass, rebaseline, spec, baseline, runtime, groups, statuses, images, date
        case resolvedVars = "resolved_vars"
        case inputSetSHA256 = "input_set_sha256"
        case backendErrors = "backend_errors"
    }

    /// The table the Python battery runner prints, and its last line.
    public var table: String {
        func pad(_ s: String, _ n: Int, right: Bool = false) -> String {
            if s.count >= n { return s }
            let fill = String(repeating: " ", count: n - s.count)
            return right ? fill + s : s + fill
        }
        var lines = ["\(pad("group", 24)) \(pad("mode", 10)) \(pad("n", 3, right: true)) \(pad("weighted", 9, right: true)) \(pad("floor", 7, right: true)) \(pad("semantic", 9, right: true))  status"]
        for s in statuses {
            guard let r = groups[s.group] else { continue }
            let floor = s.floor.map { String(format: "%.2f", $0) } ?? ""
            let sem = r.semAcc.map { String(format: "%.2f", $0) } ?? ""
            lines.append("\(pad(s.group, 24)) \(pad(r.mode.rawValue, 10)) \(pad(String(r.n), 3, right: true)) \(pad(String(format: "%.2f", r.acc), 9, right: true)) \(pad(floor, 7, right: true)) \(pad(sem, 9, right: true))  \(s.status)")
        }
        lines.append("BATTERY: " + (pass ? "PASS" : "FAIL"))
        return lines.joined(separator: "\n")
    }
}

public enum BatteryRunner {
    public static func run(spec: BatterySpec, specURL: URL? = nil, gate: BatterySpec.Gate, baselineURL: URL?, verdicts: BatteryVerdictSource,
                           vars: [String: String]? = nil, rebaseline: Bool = false, note: (String) -> Void = { _ in }) throws -> BatteryReport {
        let v = vars ?? spec.resolvedVars()
        let groups = try spec.resolve(gate: gate, vars: v)
        let baselineBefore = baselineURL.flatMap { try? ContentHash.sha256Hex(fileAt: $0) }
        var results: [String: BatteryGroupResult] = [:]
        var order: [String] = []
        var images: [BatteryImageRow] = []
        var errors: [BatteryReport.BackendError] = []
        let total = groups.reduce(0) { $0 + $1.files.count }
        var done = 0
        for g in groups {
            var ok = 0, n = 0, semOK = 0, semN = 0
            for path in g.files {
                done += 1
                let url = URL(fileURLWithPath: path)
                do {
                    let before = try ContentHash.sha256Hex(fileAt: url)
                    let r = try verdicts.verdict(for: url)
                    guard try ContentHash.sha256Hex(fileAt: url) == before else { throw VeilGardeFailure.data("input bytes changed while inference was running: \(path)") }
                    n += 1
                    if r.weighted == g.want { ok += 1 }
                    if let sem = r.semanticScore {
                        semN += 1
                        if (sem > 0.5) == (g.want == "generated") { semOK += 1 }
                    }
                    images.append(BatteryImageRow(path: path, inputSHA256: before, group: g.name, want: g.want, weightedPred: r.weighted,
                                                  weightedP: r.weightedScore, semScore: r.semanticScore, capPresent: r.capturePresent))
                } catch {
                    note("  ! \(url.lastPathComponent): \(error)")
                    errors.append(.init(path: path, group: g.name, error: "\(error)"))
                }
                if done % 25 == 0 { note("battery: \(done) of \(total) images") }
            }
            results[g.name] = BatteryGroupResult(acc: Double(ok) / Double(max(n, 1)), n: n, expectedN: g.files.count, inputComplete: n == g.files.count,
                                                 semAcc: semN > 0 ? Double(semOK) / Double(semN) : nil, mode: g.mode, want: g.want)
            order.append(g.name)
        }

        let baselineExists = baselineURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        var baseline: [String: BatteryGroupResult] = [:]
        if let baselineURL, baselineExists, !rebaseline {
            baseline = try JSONDecoder().decode([String: BatteryGroupResult].self, from: Data(contentsOf: baselineURL))
        }
        let tol = spec.tolerance
        var passed = errors.isEmpty && (baselineExists || rebaseline)
        var statuses: [BatteryReport.Status] = []
        for name in order {
            let r = results[name]!
            let floor = baseline[name]?.acc
            var status = "·"
            switch r.mode {
            case .hard, .hardSemantic:
                status = r.acc == 1.0 ? "PASS" : "FAIL"
                passed = passed && r.acc == 1.0
                if r.mode == .hardSemantic && (r.semAcc ?? 0) < 1.0 { status = "FAIL(sem)"; passed = false }
            case .ratchet, .ratchetSemantic:
                if let floor {
                    status = r.acc >= floor - tol ? "PASS" : (r.expectedN == 0 ? "FAIL(no images)" : String(format: "FAIL(<%.2f)", floor))
                    passed = passed && r.acc >= floor - tol
                    if r.mode == .ratchetSemantic, let sf = baseline[name]?.semAcc, (r.semAcc ?? 0) < sf - tol { status = "FAIL(sem)"; passed = false }
                }
            case .taxonomy, .report:
                break
            }
            if r.inputComplete == false { status = "FAIL(input)"; passed = false }
            statuses.append(.init(group: name, status: status, floor: floor))
        }
        if rebaseline, gate == .full, let baselineURL {
            try JSONCoding.write(results, to: baselineURL)
        }
        let baselineAfter = baselineURL.flatMap { try? ContentHash.sha256Hex(fileAt: $0) }
        return BatteryReport(backend: verdicts.runtime["backend"] ?? "unknown", gate: gate, pass: passed, rebaseline: rebaseline, resolvedVars: v,
                             spec: .init(path: specURL?.path ?? "", sha256: specURL.flatMap { try? ContentHash.sha256Hex(fileAt: $0) }),
                             baseline: .init(path: baselineURL?.path ?? "", sha256Before: baselineBefore, sha256After: baselineAfter,
                                             changed: baselineBefore != baselineAfter),
                             runtime: verdicts.runtime, inputSetSHA256: inputSetHash(images), backendErrors: errors, groups: results,
                             statuses: statuses, images: images, date: Date())
    }

    /// The Python runner's input_set_hash: SHA-256 of json.dumps([{group, path, sha256}], sort_keys,
    /// compact separators), with Python's ASCII escaping, so the two runners' hashes compare.
    public static func inputSetHash(_ images: [BatteryImageRow]) -> String {
        let body = images.map { "{\"group\":\(PythonJSON.string($0.group)),\"path\":\(PythonJSON.string($0.path)),\"sha256\":\(PythonJSON.string($0.inputSHA256))}" }
        return ContentHash.sha256Hex("[" + body.joined(separator: ",") + "]")
    }
}

/// Python's json.dumps string escaping (ensure_ascii): quotes, backslashes and control
/// characters escaped, every non-ASCII code unit as \uXXXX.
enum PythonJSON {
    static func string(_ s: String) -> String {
        var out = "\""
        for unit in s.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20..<0x7F: out.unicodeScalars.append(Unicode.Scalar(unit)!)
            default: out += String(format: "\\u%04x", unit)
            }
        }
        return out + "\""
    }
}
