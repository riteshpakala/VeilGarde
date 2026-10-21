//
//  ResearchCompare.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde research compare`: one detector judged against another from their censuses,
//        image by image: correct calls by label, the calls the variant moved to the right label and
//        to the wrong one, the iPhone originals' routed real share, and the battery's verdict, read
//        against rules fixed before any comparison runs (DetectorComparisonRules).
//  PIN:  Reads only the JSONs `research census` and `flywheel battery` wrote, joined by image path.
//        The labelled images R2 counts are the census rows under a final_mixed folder (200 in the
//        default census); the iPhone originals are the second census of each side. A census written
//        before 2026-10-21 reads as is. Writes <work area>/research/compare-<name>-<stamp>.json.
//

import ArgumentParser
import Foundation
import VeilGarde

/// The comparison's rules, fixed before any comparison runs (ledger decision-99, the sensor and warp
/// rules retired on 2026-10-21).
struct DetectorComparisonRules: Codable {
    var maxCorrectLoss = 2

    var text: [String] {
        [
            "R1. The full battery decides PASS or FAIL with its recorded floors.",
            "R2. A part is not necessary only when the battery passes without it, the labelled final_mixed census images lose at most \(maxCorrectLoss) correct calls against the detector with the part (inconclusive counts as wrong), and the changed calls moved to the wrong label are no more than those moved to the right one.",
            "R3. Every comparison is reported whatever another one found; the store's images, final_mixed's among them, trained the shipped models.",
        ]
    }
}

struct CompareSide: Codable {
    var census: String
    var iphone: String?
    var provenance: [String: String]?
    /// Labelled final_mixed images called right, by label, and their total.
    var finalMixedCorrect: [String: Int]
    var finalMixedImages: Int
    /// Every labelled census image called right, and their total.
    var labelledCorrect: Int
    var labelledImages: Int
    var iphoneImages: Int?
    var iphoneRoutedReal: Double?
}

struct CompareReport: Codable {
    var date: Date
    var name: String
    var judge: String
    var rules: [String]
    var reference: CompareSide
    var variant: CompareSide
    var joined: Int
    var unmatched: Int
    /// Labelled images whose routed call moved, and where it moved.
    var moved: Int
    var movedToRight: Int
    var movedToWrong: Int
    var battery: String?
    var batteryPass: Bool?
    var batteryStatuses: [String: String]?
    var verdict: String
    var reasons: [String]
}

extension ResearchCommand {
    struct Compare: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "compare", abstract: "Judge a detector variant against a reference from their censuses and battery report.",
            discussion: "--judge part applies R2 (is the part taken out necessary); --judge none only measures.")
        @Option(help: "The reference's census JSON.") var reference: String
        @Option(help: "The variant's census JSON.") var variant: String
        @Option(name: .customLong("reference-iphone"), help: "The reference's census of the iPhone originals.") var referenceIPhone: String?
        @Option(name: .customLong("variant-iphone"), help: "The variant's census of the iPhone originals.") var variantIPhone: String?
        @Option(help: "The variant's battery report JSON.") var battery: String?
        @Option(help: "part or none.") var judge: String = "none"
        @Option(help: "A name for the variant in the report.") var name: String = "variant"
        @Option(help: "Write the report here too (`-` for stdout).") var json: String?
        @OptionGroup var workArea: WorkAreaOptions

        func run() throws {
            guarded {
                guard ["part", "none"].contains(judge) else { throw VeilGardeFailure.usage("--judge is part or none, not \(judge)") }
                let area = try workArea.resolve()
                let report = try Self.compare(name: name, judge: judge, reference: reference, variant: variant, referenceIPhone: referenceIPhone,
                                              variantIPhone: variantIPhone, battery: battery, rules: DetectorComparisonRules())
                let file = try ResearchCommand.output(area, "compare-\(name)")
                try JSONCoding.write(report, to: file)
                if let json { try emitJSON(try JSONCoding.prettyEncoder().encode(report), to: json) }
                print(Self.table(report))
                note("report: \(file.path)")
            }
        }

        static func load(_ path: String) throws -> MechanismCensus { try JSONCoding.read(MechanismCensus.self, from: datasetURL(path)) }

        static func side(_ census: MechanismCensus, path: String, iphone: MechanismCensus?, iphonePath: String?) -> CompareSide {
            let labelled = census.rows.filter { $0.label != nil }
            let finalMixed = labelled.filter { $0.path.contains("/final_mixed/") }
            var byLabel: [String: Int] = [:]
            for row in finalMixed where row.call == row.label { byLabel[row.label!, default: 0] += 1 }
            let iphoneRows = iphone?.rows ?? []
            func share(_ n: Int) -> Double? { iphoneRows.isEmpty ? nil : Double(n) / Double(iphoneRows.count) }
            return CompareSide(census: datasetURL(path).path, iphone: iphonePath.map { datasetURL($0).path }, provenance: census.provenance,
                               finalMixedCorrect: byLabel, finalMixedImages: finalMixed.count, labelledCorrect: labelled.filter { $0.call == $0.label }.count,
                               labelledImages: labelled.count, iphoneImages: iphone.map { _ in iphoneRows.count },
                               iphoneRoutedReal: share(iphoneRows.filter { $0.call == "real" }.count))
        }

        static func compare(name: String, judge: String, reference: String, variant: String, referenceIPhone: String?, variantIPhone: String?,
                            battery: String?, rules: DetectorComparisonRules) throws -> CompareReport {
            let ref = try load(reference), v = try load(variant)
            let refI = try referenceIPhone.map(load), vI = try variantIPhone.map(load)
            let a = side(ref, path: reference, iphone: refI, iphonePath: referenceIPhone)
            let b = side(v, path: variant, iphone: vI, iphonePath: variantIPhone)
            let byPath = Dictionary(v.rows.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            var joined = 0, unmatched = 0, moved = 0, right = 0, wrong = 0
            for row in ref.rows {
                guard let other = byPath[row.path] else { unmatched += 1; continue }
                joined += 1
                guard let label = row.label, row.call != other.call else { continue }
                moved += 1
                if other.call == label { right += 1 } else { wrong += 1 }
            }
            var pass: Bool? = nil, statuses: [String: String]? = nil
            if let battery {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: datasetURL(battery))) as? [String: Any]
                pass = object?["pass"] as? Bool
                // The battery report lists its statuses as [{group, status, floor}].
                if let list = object?["statuses"] as? [[String: Any]] {
                    statuses = Dictionary(list.compactMap { s in (s["group"] as? String).map { ($0, "\(s["status"] ?? "")") } }, uniquingKeysWith: { first, _ in first })
                }
            }
            let loss = a.finalMixedCorrect.values.reduce(0, +) - b.finalMixedCorrect.values.reduce(0, +)
            var reasons: [String] = []
            var verdict = "measured"
            switch judge {
            case "part":
                if pass != true { reasons.append("the battery does not pass without it (\(pass.map { $0 ? "PASS" : "FAIL" } ?? "no report"))") }
                if loss > rules.maxCorrectLoss { reasons.append("the labelled final_mixed images lose \(loss) correct calls (bar \(rules.maxCorrectLoss))") }
                if wrong > right { reasons.append("\(wrong) calls moved to the wrong label against \(right) to the right one") }
                verdict = reasons.isEmpty ? "not necessary (R2)" : "necessary (R2)"
            default: break
            }
            return CompareReport(date: Date(), name: name, judge: judge, rules: rules.text, reference: a, variant: b, joined: joined, unmatched: unmatched,
                                 moved: moved, movedToRight: right, movedToWrong: wrong, battery: battery.map { datasetURL($0).path }, batteryPass: pass, batteryStatuses: statuses, verdict: verdict, reasons: reasons)
        }

        static func table(_ r: CompareReport) -> String {
            func fm(_ s: CompareSide) -> String {
                "final_mixed correct \(s.finalMixedCorrect.values.reduce(0, +)) of \(s.finalMixedImages) (" + s.finalMixedCorrect.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")"
                    + "; labelled \(s.labelledCorrect) of \(s.labelledImages)"
                    + (s.iphoneImages.map { n in String(format: "; iPhone %d: routed real %.3f", n, s.iphoneRoutedReal ?? .nan) } ?? "")
            }
            var lines = ["\(r.name) (\(r.judge)): \(r.verdict)"]
            lines.append("  reference: " + fm(r.reference))
            lines.append("  variant:   " + fm(r.variant))
            lines.append("  \(r.joined) images joined (\(r.unmatched) unmatched); \(r.moved) labelled calls moved, \(r.movedToRight) to the right label, \(r.movedToWrong) to the wrong one")
            if let pass = r.batteryPass { lines.append("  battery: \(pass ? "PASS" : "FAIL")" + (r.batteryStatuses.map { " " + $0.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") } ?? "")) }
            for reason in r.reasons { lines.append("  - " + reason) }
            return lines.joined(separator: "\n")
        }
    }
}
