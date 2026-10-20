//
//  SensorCalibration.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The camera-sensor score's contract. The warp lens's tile vote (the fraction of 32-px tiles
//        the warp model reads above 0.5) is the score, and two cuts on it make the call: real at or
//        below the first, generated at or above the second, inconclusive between (schema 2). The
//        contract is bound to the exact model bytes it was fitted on and to the model's column count.
//        Schema 1 contracts, Garde's, still load: a Platt projection σ(coef·logit(fraction) +
//        intercept) judged against a threshold and an open band, or the identity.
//  PIN:  Shipped: real ≤ 0.71687186, generated ≥ 0.83653802 on the vote, variant warp19, bound to
//        sha 516119c9…. The cuts are where Garde's Platt contract (coef 0.48908749922126266,
//        intercept −0.09094760943132153, T 0.6298664647384551, band 0.04, fitted on 65% of
//        validation with the threshold chosen on the other 35%) changes its call, found over every
//        float32 vote, so the call is the same on every input (the pruning study: Platt is monotone,
//        so it was only ever two cuts). Independent of the 0.56 weighted operating point. A present
//        but invalid or mismatched contract fails closed; only an absent one falls back to identity
//        at T = 0.5.
//

import Foundation

public enum SensorCalibrationTransform: String, Codable, Sendable, Equatable {
    case identity
    case platt
    /// Two cuts on the raw tile vote (schema 2).
    case cuts
}

/// The sensor call as two cuts on the tile vote: real at or below the first, generated at or above
/// the second, inconclusive between. A cut outside [0, 1] never fires: −1 for a contract that never
/// calls real, 2 for one that never calls generated.
public struct SensorCuts: Codable, Sendable, Equatable {
    public let realAtOrBelow: Double
    public let generatedAtOrAbove: Double

    public init(realAtOrBelow: Double, generatedAtOrAbove: Double) {
        self.realAtOrBelow = realAtOrBelow
        self.generatedAtOrAbove = generatedAtOrAbove
    }

    enum CodingKeys: String, CodingKey {
        case realAtOrBelow = "real_at_or_below"
        case generatedAtOrAbove = "generated_at_or_above"
    }

    public var isValid: Bool { realAtOrBelow.isFinite && generatedAtOrAbove.isFinite && realAtOrBelow < generatedAtOrAbove }

    public func call(_ vote: Float) -> String {
        let v = Double(vote)
        return v <= realAtOrBelow ? "real" : v >= generatedAtOrAbove ? "generated" : "inconclusive"
    }
}

public struct SensorPlattPayload: Codable, Sendable, Equatable {
    public let coef: Double
    public let intercept: Double

    public init(coef: Double, intercept: Double) {
        self.coef = coef
        self.intercept = intercept
    }
}

public enum SensorCalibrationError: Error, LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case invalidContract(String)
    case modelMismatch(expected: String, actual: String)
    case variantMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported sensor calibration schema_version \(version)"
        case .invalidContract(let reason):
            return "Invalid sensor calibration contract: \(reason)"
        case .modelMismatch(let expected, let actual):
            return "Sensor calibration model hash mismatch (contract \(expected), runtime \(actual))"
        case .variantMismatch(let expected, let actual):
            return "Sensor calibration variant mismatch (contract \(expected), runtime \(actual))"
        }
    }
}

public struct SensorCalibrationContract: Sendable, Equatable {
    public static let schemaVersion = 1
    /// The schema of a contract that is two cuts.
    public static let cutsSchemaVersion = 2
    public static let scoreSemantics = "image_majority_fraction"
    public static let generatedComparison = "strictly_greater_than_threshold"
    public static let cutsComparison = "at_or_above_generated_cut"
    public static let trustLaw = "v1_decisive_native_capture_present_valid_and_governing_agreement"

    public let sensorVariant: String
    public let sensorModelSHA256: String
    public let transform: SensorCalibrationTransform
    public let plattPayload: SensorPlattPayload?
    public let cuts: SensorCuts?
    /// For two cuts, their midpoint and half their distance: the band the cuts are.
    public let decisionThreshold: Float
    public let uncertainBand: Float
    public let nativeRoutes: [String]
    /// SHA-256 of the exact artifact bytes; nil only for the absent-resource fallback.
    public let artifactSHA256: String?

    /// Release provenance: the artifact's hash, or for the fallback the canonical compact-JSON
    /// hash of the equivalent identity contract (the campaign's definition).
    public var provenanceSHA256: String {
        artifactSHA256 ?? ContentHash.sha256Hex(canonicalJSONData())
    }

    /// Stable identity for telemetry; a fallback can never masquerade as release-bound data.
    public var identity: String {
        artifactSHA256 == nil ? "identity-fallback" : transform.rawValue
    }

    /// This contract's schema: 2 for two cuts, else 1.
    public var schema: Int { transform == .cuts ? Self.cutsSchemaVersion : Self.schemaVersion }
    /// How it calls generated: at or above a cut, or strictly above a threshold.
    public var comparison: String { transform == .cuts ? Self.cutsComparison : Self.generatedComparison }

    /// A contract that is two cuts on the vote.
    public static func twoCuts(_ cuts: SensorCuts, sensorVariant: String, sensorModelSHA256: String, nativeRoutes: [String] = ["camera"],
                               artifactSHA256: String? = nil) throws -> SensorCalibrationContract {
        try SensorCalibrationContract(sensorVariant: sensorVariant, sensorModelSHA256: sensorModelSHA256, transform: .cuts, cuts: cuts,
                                      decisionThreshold: Float((cuts.realAtOrBelow + cuts.generatedAtOrAbove) / 2),
                                      uncertainBand: Float((cuts.generatedAtOrAbove - cuts.realAtOrBelow) / 2),
                                      nativeRoutes: nativeRoutes, artifactSHA256: artifactSHA256)
    }

    public init(sensorVariant: String, sensorModelSHA256: String, transform: SensorCalibrationTransform,
                plattPayload: SensorPlattPayload? = nil, cuts: SensorCuts? = nil, decisionThreshold: Float, uncertainBand: Float,
                nativeRoutes: [String] = ["camera"], artifactSHA256: String? = nil) throws {
        guard !sensorVariant.isEmpty else {
            throw SensorCalibrationError.invalidContract("sensor_variant is empty")
        }
        guard Self.isSHA256(sensorModelSHA256) else {
            throw SensorCalibrationError.invalidContract("sensor_model_sha256 is not 64 lowercase hex characters")
        }
        // Two cuts state their own midpoint and half-width; a cut that never fires puts them outside these bounds.
        guard decisionThreshold.isFinite, transform == .cuts || (0...1).contains(decisionThreshold) else {
            throw SensorCalibrationError.invalidContract("decision_threshold must be finite and in [0,1]")
        }
        guard uncertainBand.isFinite, transform == .cuts || (uncertainBand >= 0 && uncertainBand < 0.5) else {
            throw SensorCalibrationError.invalidContract("uncertain_band must be finite and in [0,0.5)")
        }
        if transform == .platt {
            guard let payload = plattPayload, payload.coef.isFinite, payload.intercept.isFinite else {
                throw SensorCalibrationError.invalidContract("Platt calibration requires finite coef/intercept")
            }
        } else if plattPayload != nil {
            throw SensorCalibrationError.invalidContract("\(transform.rawValue) calibration must not carry a Platt payload")
        }
        if transform == .cuts {
            guard let cuts, cuts.isValid else {
                throw SensorCalibrationError.invalidContract("two cuts need finite cuts, real_at_or_below < generated_at_or_above")
            }
        } else if cuts != nil {
            throw SensorCalibrationError.invalidContract("\(transform.rawValue) calibration must not carry cuts")
        }
        if let artifactSHA256, !Self.isSHA256(artifactSHA256) {
            throw SensorCalibrationError.invalidContract("artifact SHA-256 is not 64 lowercase hex characters")
        }
        guard nativeRoutes.allSatisfy({ !$0.isEmpty }) else {
            throw SensorCalibrationError.invalidContract("native_routes contains an empty route")
        }
        self.sensorVariant = sensorVariant
        self.sensorModelSHA256 = sensorModelSHA256
        self.transform = transform
        self.plattPayload = plattPayload
        self.cuts = cuts
        self.decisionThreshold = decisionThreshold
        self.uncertainBand = uncertainBand
        self.nativeRoutes = nativeRoutes
        self.artifactSHA256 = artifactSHA256
    }

    /// Decodes and validates an artifact, bound to the model bytes and the column variant.
    public static func decode(_ data: Data, expectedModelSHA256: String, expectedSensorVariant: String) throws -> SensorCalibrationContract {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw SensorCalibrationError.invalidContract("JSON decode failed: \(error.localizedDescription)")
        }
        guard payload.schemaVersion == schemaVersion || payload.schemaVersion == cutsSchemaVersion else {
            throw SensorCalibrationError.unsupportedSchema(payload.schemaVersion)
        }
        guard (payload.schemaVersion == cutsSchemaVersion) == (payload.calibration == SensorCalibrationTransform.cuts.rawValue) else {
            throw SensorCalibrationError.invalidContract("schema_version \(cutsSchemaVersion) is two cuts, and two cuts are schema_version \(cutsSchemaVersion)")
        }
        guard payload.scoreSemantics == scoreSemantics else {
            throw SensorCalibrationError.invalidContract("score_semantics must be \(scoreSemantics)")
        }
        let comparison = payload.schemaVersion == cutsSchemaVersion ? cutsComparison : generatedComparison
        guard payload.generatedComparison == comparison else {
            throw SensorCalibrationError.invalidContract("generated_comparison must be \(comparison)")
        }
        guard payload.trustLaw == trustLaw else { throw SensorCalibrationError.invalidContract("trust_law must be \(trustLaw)") }
        guard payload.sensorModelSHA256 == expectedModelSHA256 else {
            throw SensorCalibrationError.modelMismatch(expected: payload.sensorModelSHA256, actual: expectedModelSHA256)
        }
        guard payload.sensorVariant == expectedSensorVariant else {
            throw SensorCalibrationError.variantMismatch(expected: payload.sensorVariant, actual: expectedSensorVariant)
        }
        guard let transform = SensorCalibrationTransform(rawValue: payload.calibration) else {
            throw SensorCalibrationError.invalidContract("calibration must be identity, platt or cuts")
        }
        if transform == .cuts {
            guard let cuts = payload.cuts else { throw SensorCalibrationError.invalidContract("two cuts need their cuts") }
            let contract = try twoCuts(cuts, sensorVariant: payload.sensorVariant, sensorModelSHA256: payload.sensorModelSHA256,
                                       nativeRoutes: payload.nativeRoutes, artifactSHA256: ContentHash.sha256Hex(data))
            // The threshold and band a cuts file states are the cuts' own midpoint and half-width, or it is refused.
            guard abs(payload.decisionThreshold - (cuts.realAtOrBelow + cuts.generatedAtOrAbove) / 2) < 1e-9,
                  abs(payload.uncertainBand - (cuts.generatedAtOrAbove - cuts.realAtOrBelow) / 2) < 1e-9 else {
                throw SensorCalibrationError.invalidContract("decision_threshold and uncertain_band must be the cuts' midpoint and half-width")
            }
            return contract
        }
        return try SensorCalibrationContract(
            sensorVariant: payload.sensorVariant, sensorModelSHA256: payload.sensorModelSHA256, transform: transform,
            plattPayload: payload.plattPayload, decisionThreshold: Float(payload.decisionThreshold),
            uncertainBand: Float(payload.uncertainBand), nativeRoutes: payload.nativeRoutes,
            artifactSHA256: ContentHash.sha256Hex(data))
    }

    /// The identity behaviour used only when no contract exists: raw fraction, T = 0.5, caller band.
    public static func identityFallback(sensorVariant: String, sensorModelSHA256: String, uncertainBand: Float) throws -> SensorCalibrationContract {
        try SensorCalibrationContract(sensorVariant: sensorVariant, sensorModelSHA256: sensorModelSHA256, transform: .identity,
                                      decisionThreshold: 0.5, uncertainBand: uncertainBand, nativeRoutes: ["camera"], artifactSHA256: nil)
    }

    /// The contract at `url`, or the identity fallback when there is none.
    public static func load(url: URL?, sensorVariant: String, sensorModelSHA256: String, fallbackBand: Float) throws -> SensorCalibrationContract {
        guard let url else {
            return try .identityFallback(sensorVariant: sensorVariant, sensorModelSHA256: sensorModelSHA256, uncertainBand: fallbackBand)
        }
        return try .decode(Data(contentsOf: url), expectedModelSHA256: sensorModelSHA256, expectedSensorVariant: sensorVariant)
    }

    /// The variant a sensor model's column count names.
    public static func variant(featureCount: Int) throws -> String {
        switch featureCount {
        case 19: return "warp19"
        case 35: return "warp19_e16"
        case 40: return "warp40"
        default:
            throw SensorCalibrationError.invalidContract("sensor model consumes \(featureCount) features; supported widths are 19, 35, and 40")
        }
    }

    /// Platt on logit(raw), with campaign_support.apply_platt's 1e-6 clipping and a stable sigmoid; for two cuts and the
    /// identity, the vote itself.
    public func calibratedProbability(_ rawProbability: Float) -> Float {
        let raw = min(max(rawProbability, 0), 1)
        guard transform == .platt, let payload = plattPayload else { return raw }
        let clipped = min(max(Double(raw), 1e-6), 1 - 1e-6)
        let logit = log(clipped / (1 - clipped))
        let z = payload.coef * logit + payload.intercept
        let probability: Double
        if z >= 0 {
            probability = 1 / (1 + exp(-z))
        } else {
            let ez = exp(z)
            probability = ez / (1 + ez)
        }
        return Float(probability)
    }

    /// The open band; generated is strictly greater than the threshold. Two cuts call the vote against the cuts.
    public func prediction(for calibratedProbability: Float) -> String {
        if transform == .cuts, let cuts { return cuts.call(calibratedProbability) }
        if abs(calibratedProbability - decisionThreshold) < uncertainBand { return "inconclusive" }
        return calibratedProbability > decisionThreshold ? "generated" : "real"
    }

    /// The two cuts that call every float32 vote exactly as this contract does: the largest vote it calls real and
    /// the smallest it calls generated, found by bisection over the bit patterns of [0, 1] (the call is monotone in
    /// the vote, as a Platt projection is). A side the contract never calls gets a cut that never fires.
    public func equivalentCuts() -> SensorCuts {
        if let cuts { return cuts }
        func call(_ bits: UInt32) -> String { prediction(for: calibratedProbability(Float(bitPattern: bits))) }
        let one = Float(1).bitPattern
        var lastReal = -1.0
        if call(0) == "real" {
            var lo: UInt32 = 0, hi: UInt32 = one          // call(lo) is real; call(hi) is not, unless every vote is
            if call(one) == "real" { lo = one }
            while hi - lo > 1 { let mid = lo + (hi - lo) / 2; if call(mid) == "real" { lo = mid } else { hi = mid } }
            lastReal = Double(Float(bitPattern: lo))
        }
        var firstGenerated = 2.0
        if call(one) == "generated" {
            var a: UInt32 = 0, b: UInt32 = one            // call(b) is generated; call(a) is not, unless every vote is
            if call(0) == "generated" { b = 0 }
            while b - a > 1 { let mid = a + (b - a) / 2; if call(mid) == "generated" { b = mid } else { a = mid } }
            firstGenerated = Double(Float(bitPattern: b))
        }
        return SensorCuts(realAtOrBelow: lastReal, generatedAtOrAbove: firstGenerated)
    }

    private func canonicalJSONData() -> Data {
        let encodedPlatt: Any
        if let plattPayload {
            encodedPlatt = ["coef": plattPayload.coef, "intercept": plattPayload.intercept]
        } else {
            encodedPlatt = NSNull()
        }
        func contractNumber(_ value: Float) -> NSDecimalNumber {
            var spelling = String(format: "%.8f", value)
            while spelling.last == "0" { spelling.removeLast() }
            if spelling.last == "." { spelling.append("0") }
            return NSDecimalNumber(string: spelling)
        }
        let payload: [String: Any] = [
            "schema_version": Self.schemaVersion,
            "sensor_variant": sensorVariant,
            "sensor_model_sha256": sensorModelSHA256,
            "score_semantics": Self.scoreSemantics,
            "calibration": transform.rawValue,
            "platt_payload": encodedPlatt,
            // The shortest float32 decimal (0.5 and 0.04 for the fallback), matching Python's values.
            "decision_threshold": contractNumber(decisionThreshold),
            "uncertain_band": contractNumber(uncertainBand),
            "generated_comparison": Self.generatedComparison,
            "native_routes": nativeRoutes,
            "trust_law": Self.trustLaw,
        ]
        // Initialization excludes non-finite numbers, so serialization cannot fail.
        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private struct Payload: Decodable {
        let schemaVersion: Int
        let sensorVariant: String
        let sensorModelSHA256: String
        let scoreSemantics: String
        let calibration: String
        let plattPayload: SensorPlattPayload?
        let cuts: SensorCuts?
        let decisionThreshold: Double
        let uncertainBand: Double
        let generatedComparison: String
        let nativeRoutes: [String]
        let trustLaw: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case sensorVariant = "sensor_variant"
            case sensorModelSHA256 = "sensor_model_sha256"
            case scoreSemantics = "score_semantics"
            case calibration, cuts
            case plattPayload = "platt_payload"
            case decisionThreshold = "decision_threshold"
            case uncertainBand = "uncertain_band"
            case generatedComparison = "generated_comparison"
            case nativeRoutes = "native_routes"
            case trustLaw = "trust_law"
        }
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }
}

/// Where a cuts file's cuts came from: the Platt (or identity) contract they reproduce, kept for audit (decode does
/// not read it).
public struct SensorCutsProvenance: Codable, Sendable, Equatable {
    public var calibration: SensorCalibrationTransform
    public var plattPayload: SensorPlattPayload?
    public var decisionThreshold: Double
    public var uncertainBand: Double

    public init(calibration: SensorCalibrationTransform, plattPayload: SensorPlattPayload?, decisionThreshold: Double, uncertainBand: Double) {
        self.calibration = calibration
        self.plattPayload = plattPayload
        self.decisionThreshold = decisionThreshold
        self.uncertainBand = uncertainBand
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(calibration, forKey: .calibration)
        if let plattPayload { try c.encode(plattPayload, forKey: .plattPayload) } else { try c.encodeNil(forKey: .plattPayload) }
        try c.encode(decisionThreshold, forKey: .decisionThreshold)
        try c.encode(uncertainBand, forKey: .uncertainBand)
    }

    enum CodingKeys: String, CodingKey {
        case calibration
        case plattPayload = "platt_payload"
        case decisionThreshold = "decision_threshold"
        case uncertainBand = "uncertain_band"
    }
}

/// The contract file as the trainer writes it: the keys `decode` validates, sorted. A cuts file (schema 2) also
/// states the cuts' midpoint and half-width as its threshold and band, and the Platt contract it was derived from.
public struct SensorCalibrationFile: Codable, Sendable, Equatable {
    public var schemaVersion = SensorCalibrationContract.schemaVersion
    public var sensorVariant: String
    public var sensorModelSHA256: String
    public var scoreSemantics = SensorCalibrationContract.scoreSemantics
    public var calibration: SensorCalibrationTransform
    public var plattPayload: SensorPlattPayload?
    public var cuts: SensorCuts?
    public var derivedFrom: SensorCutsProvenance?
    public var decisionThreshold: Double
    public var uncertainBand: Double
    public var generatedComparison = SensorCalibrationContract.generatedComparison
    public var nativeRoutes = ["camera"]
    public var trustLaw = SensorCalibrationContract.trustLaw

    public init(sensorVariant: String, sensorModelSHA256: String, calibration: SensorCalibrationTransform,
                plattPayload: SensorPlattPayload?, decisionThreshold: Double, uncertainBand: Double) {
        self.sensorVariant = sensorVariant
        self.sensorModelSHA256 = sensorModelSHA256
        self.calibration = calibration
        self.plattPayload = plattPayload
        self.decisionThreshold = decisionThreshold
        self.uncertainBand = uncertainBand
    }

    /// The two cuts that call every vote as a Platt or identity contract does; nil when it is two cuts already.
    public static func twoCuts(from platt: SensorCalibrationContract) -> SensorCalibrationFile? {
        guard platt.transform != .cuts else { return nil }
        let cuts = platt.equivalentCuts()
        var f = SensorCalibrationFile(sensorVariant: platt.sensorVariant, sensorModelSHA256: platt.sensorModelSHA256, calibration: .cuts,
                                      plattPayload: nil, decisionThreshold: (cuts.realAtOrBelow + cuts.generatedAtOrAbove) / 2,
                                      uncertainBand: (cuts.generatedAtOrAbove - cuts.realAtOrBelow) / 2)
        f.schemaVersion = SensorCalibrationContract.cutsSchemaVersion
        f.generatedComparison = SensorCalibrationContract.cutsComparison
        f.cuts = cuts
        f.nativeRoutes = platt.nativeRoutes
        f.derivedFrom = SensorCutsProvenance(calibration: platt.transform, plattPayload: platt.plattPayload,
                                             decisionThreshold: Double(platt.decisionThreshold), uncertainBand: Double(platt.uncertainBand))
        return f
    }

    enum CodingKeys: String, CodingKey {
        case calibration, cuts
        case derivedFrom = "derived_from"
        case schemaVersion = "schema_version"
        case sensorVariant = "sensor_variant"
        case sensorModelSHA256 = "sensor_model_sha256"
        case scoreSemantics = "score_semantics"
        case plattPayload = "platt_payload"
        case decisionThreshold = "decision_threshold"
        case uncertainBand = "uncertain_band"
        case generatedComparison = "generated_comparison"
        case nativeRoutes = "native_routes"
        case trustLaw = "trust_law"
    }

    /// Encodes `platt_payload: null` for identity, as the shipped file does.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(calibration, forKey: .calibration)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(sensorVariant, forKey: .sensorVariant)
        try c.encode(sensorModelSHA256, forKey: .sensorModelSHA256)
        try c.encode(scoreSemantics, forKey: .scoreSemantics)
        if let plattPayload { try c.encode(plattPayload, forKey: .plattPayload) } else { try c.encodeNil(forKey: .plattPayload) }
        try c.encodeIfPresent(cuts, forKey: .cuts)
        try c.encodeIfPresent(derivedFrom, forKey: .derivedFrom)
        try c.encode(decisionThreshold, forKey: .decisionThreshold)
        try c.encode(uncertainBand, forKey: .uncertainBand)
        try c.encode(generatedComparison, forKey: .generatedComparison)
        try c.encode(nativeRoutes, forKey: .nativeRoutes)
        try c.encode(trustLaw, forKey: .trustLaw)
    }
}
