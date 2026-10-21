//
//  BatteryVerdicts.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What the battery reads off one image: the weighted verdict and score, the semantic
//        tile majority, and whether a capture signature is present. The production source runs
//        the full detector on a bundle in process; tests hand the runner canned verdicts.
//  PIN:  The values are read from the result JSON the detector writes (schema v2, Garde's bytes),
//        exactly as the Python runner's route backend reads Garde's --route-json:
//        verdict.weighted.prediction and .score, the share of semantic_tiles cells above 0.5
//        (nil without tiles), capture.present. A study may run the battery with the warp lens as
//        the camera base (`flywheel battery --base warp`); the runtime says which base ran, and
//        promote and rollback always gate the detector as it ships.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeInference

public struct BatteryVerdict: Codable, Sendable, Equatable {
    public var weighted: String
    public var weightedScore: Double
    public var semanticScore: Double?
    public var capturePresent: Bool

    public init(weighted: String, weightedScore: Double, semanticScore: Double?, capturePresent: Bool) {
        self.weighted = weighted
        self.weightedScore = weightedScore
        self.semanticScore = semanticScore
        self.capturePresent = capturePresent
    }

    /// Reads a result JSON (the detector's or Garde's --route-json).
    public init(resultJSON data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let verdict = object["verdict"] as? [String: Any], let weighted = verdict["weighted"] as? [String: Any],
              let prediction = weighted["prediction"] as? String else {
            throw VeilGardeFailure.data("a result JSON without verdict.weighted.prediction")
        }
        self.weighted = prediction
        self.weightedScore = (weighted["score"] as? NSNumber)?.doubleValue ?? .nan
        let cells = ((object["semantic_tiles"] as? [[NSNumber]]) ?? []).flatMap { $0 }.map(\.doubleValue)
        self.semanticScore = cells.isEmpty ? nil : Double(cells.filter { $0 > 0.5 }.count) / Double(cells.count)
        self.capturePresent = ((object["capture"] as? [String: Any])?["present"] as? Bool) ?? false
    }
}

public protocol BatteryVerdictSource: AnyObject {
    func verdict(for url: URL) throws -> BatteryVerdict
    /// What produced the verdicts, for the report.
    var runtime: [String: String] { get }
}

/// The full detector over a bundle, in process.
public final class DetectorVerdicts: BatteryVerdictSource {
    public let bundle: DetectorBundle
    private let config: InferenceConfig
    public private(set) var runtime: [String: String]

    public init(bundle: DetectorBundle, baseExpert: BaseExpert = .fusion) {
        self.bundle = bundle
        var config = InferenceConfig(bundle: bundle)
        config.timing = false
        config.baseExpert = baseExpert
        self.config = config
        var runtime = ["backend": "veilgarde-detector", "core_version": VeilGardeVersion.string]
        runtime.merge(bundle.provenance) { _, new in new }
        if baseExpert != .fusion { runtime["base_expert"] = baseExpert.rawValue }
        self.runtime = runtime
    }

    public func verdict(for url: URL) throws -> BatteryVerdict {
        defer { LensRuntime.releaseMemory() }
        let cg = try ImageDecoding.cgImage(contentsOf: url)
        let routed = try Detector.shared.detect(cgImage: cg, config: config)
        return try BatteryVerdict(resultJSON: try ResultJSON.encode(routed.result, times: [], device: "route", route: routed.domain.rawValue))
    }
}

/// Verdicts given in advance, by path (tests, and replaying a report).
public final class CannedVerdicts: BatteryVerdictSource {
    public var verdicts: [String: BatteryVerdict]
    public var failures: Set<String>
    public let runtime: [String: String] = ["backend": "canned"]

    public init(_ verdicts: [String: BatteryVerdict], failures: Set<String> = []) {
        self.verdicts = verdicts
        self.failures = failures
    }

    public func verdict(for url: URL) throws -> BatteryVerdict {
        if failures.contains(url.path) { throw VeilGardeFailure.data("canned failure for \(url.lastPathComponent)") }
        guard let v = verdicts[url.path] else { throw VeilGardeFailure.missing("no canned verdict for \(url.path)") }
        return v
    }
}
