//
//  BatteryVerdicts.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What the battery reads off one image: the verdict and its P(AI), the semantic tile
//        majority, and whether a capture signature is present. The production source runs the full
//        detector on a bundle in process; tests hand the runner canned verdicts.
//  PIN:  The values are read from the result JSON the detector writes (schema v1):
//        verdict.prediction and .p, the share of the semantic-tiles member's grid cells above 0.5
//        (nil without that member), the capture member's present.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeInference

public struct BatteryVerdict: Codable, Sendable, Equatable {
    public var prediction: String
    public var p: Double
    public var semanticScore: Double?
    public var capturePresent: Bool

    public init(prediction: String, p: Double, semanticScore: Double?, capturePresent: Bool) {
        self.prediction = prediction
        self.p = p
        self.semanticScore = semanticScore
        self.capturePresent = capturePresent
    }

    /// Reads a schema-v1 result JSON.
    public init(resultJSON data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let verdict = object["verdict"] as? [String: Any], let prediction = verdict["prediction"] as? String else {
            throw VeilGardeFailure.data("a result JSON without verdict.prediction")
        }
        self.prediction = prediction
        self.p = (verdict["p"] as? NSNumber)?.doubleValue ?? .nan
        let stack = object["stack"] as? [[String: Any]] ?? []
        func member(_ name: String) -> [String: Any]? { stack.first { $0["name"] as? String == name } }
        let cells = ((member("semantic-tiles")?["grid"] as? [[NSNumber]]) ?? []).flatMap { $0 }.map(\.doubleValue)
        self.semanticScore = cells.isEmpty ? nil : Double(cells.filter { $0 > 0.5 }.count) / Double(cells.count)
        self.capturePresent = (member("capture")?["present"] as? Bool) ?? false
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

    public init(bundle: DetectorBundle) {
        self.bundle = bundle
        self.config = InferenceConfig(bundle: bundle)
        var runtime = ["backend": "veilgarde-detector", "core_version": VeilGardeVersion.string]
        runtime.merge(bundle.provenance) { _, new in new }
        self.runtime = runtime
    }

    public func verdict(for url: URL) throws -> BatteryVerdict {
        defer { LensRuntime.releaseMemory() }
        let cg = try ImageDecoding.cgImage(contentsOf: url)
        let result = try Detector.detect(cgImage: cg, config: config)
        return try BatteryVerdict(resultJSON: try ResultJSON.encode(result, times: [], device: "route"))
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
