//
//  SensorCalibrationTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The camera-sensor contract: the shipped pair is bound to the sensor model's bytes, and its
//        two cuts call every float32 vote as Garde's Platt contract did; a cuts file states its cuts'
//        own midpoint and band or is refused. Ported from Garde's SensorCalibrationTests: the
//        identity fallback keeps the raw fraction with an open band and Garde's provenance hash;
//        Platt is on the logit scale; decoding binds model and variant; the trainer's file form
//        decodes back.
//

import Foundation
import Testing
@testable import VeilGardeCore

@Suite("Sensor calibration")
struct SensorCalibrationTests {
    let modelHash = String(repeating: "a", count: 64)

    @Test("the shipped sensor and its calibration are a bound pair with the deployed operating point")
    func shippedPair() throws {
        let modelSHA = try ContentHash.sha256Hex(fileAt: Fixture.resource("warp_majority_tile32.xgb.json"))
        #expect(modelSHA == "516119c92d364dda3dba41dcfc42e06edf0f42e45efd3b54c44ab620f7eefe3d")
        let calibration = try SensorCalibrationContract.decode(
            Data(contentsOf: Fixture.resource("warp_sensor_calibration.json")), expectedModelSHA256: modelSHA, expectedSensorVariant: "warp19")
        #expect(calibration.transform == .cuts && calibration.schema == 2 && calibration.comparison == "at_or_above_generated_cut")
        #expect(calibration.nativeRoutes == ["camera"])
        #expect(calibration.artifactSHA256 != nil)
        #expect(calibration.calibratedProbability(0.42) == 0.42, "the score is the tile vote itself")
        #expect(calibration.prediction(for: calibration.calibratedProbability(0.90)) == "generated")
        #expect(calibration.prediction(for: calibration.calibratedProbability(0.78)) == "inconclusive")
        #expect(calibration.prediction(for: calibration.calibratedProbability(0.50)) == "real")
        let cuts = try #require(calibration.cuts)
        let lo = Float(cuts.realAtOrBelow), hi = Float(cuts.generatedAtOrAbove)
        #expect(Double(lo) == cuts.realAtOrBelow && Double(hi) == cuts.generatedAtOrAbove, "each cut is a float32 vote")
        #expect(calibration.prediction(for: lo) == "real" && calibration.prediction(for: lo.nextUp) == "inconclusive")
        #expect(calibration.prediction(for: hi) == "generated" && calibration.prediction(for: hi.nextDown) == "inconclusive")
    }

    /// Garde's shipped Platt contract, the one the shipped cuts replace.
    static func gardePlatt(_ sha: String) throws -> SensorCalibrationContract {
        try SensorCalibrationContract(sensorVariant: "warp19", sensorModelSHA256: sha, transform: .platt,
                                      plattPayload: SensorPlattPayload(coef: 0.48908749922126266, intercept: -0.09094760943132153),
                                      decisionThreshold: Float(0.6298664647384551), uncertainBand: 0.04)
    }

    @Test("the shipped cuts are where Garde's Platt contract turns, and call every vote as it did")
    func cutsEqualPlatt() throws {
        let sha = "516119c92d364dda3dba41dcfc42e06edf0f42e45efd3b54c44ab620f7eefe3d"
        let platt = try Self.gardePlatt(sha)
        let shipped = try SensorCalibrationContract.decode(Data(contentsOf: Fixture.resource("warp_sensor_calibration.json")),
                                                           expectedModelSHA256: sha, expectedSensorVariant: "warp19")
        #expect(platt.equivalentCuts() == shipped.cuts)
        func same(_ v: Float) -> Bool { shipped.prediction(for: shipped.calibratedProbability(v)) == platt.prediction(for: platt.calibratedProbability(v)) }
        var votes = 0, differ = 0
        for n in 1...1024 {
            for k in 0...n {
                votes += 1
                if !same(Float(k) / Float(n)) { differ += 1 }
            }
        }
        #expect(differ == 0, "\(differ) of \(votes) votes k/n (n ≤ 1024) called differently")
        let cuts = try #require(shipped.cuts)
        for v in [Float(cuts.realAtOrBelow), Float(cuts.generatedAtOrAbove)] { #expect(same(v) && same(v.nextUp) && same(v.nextDown)) }
        let file = try #require(SensorCalibrationFile.twoCuts(from: platt))
        let written = try SensorCalibrationContract.decode(try JSONCoding.prettyEncoder().encode(file), expectedModelSHA256: sha, expectedSensorVariant: "warp19")
        #expect(written.cuts == shipped.cuts && file.derivedFrom?.plattPayload?.coef == 0.48908749922126266)
    }

    @Test("a contract that never calls one side gets a cut that never fires, and calls as before")
    func degenerateCuts() throws {
        // σ(logit v) is v itself; T 0.01 ± 0.04 leaves no vote real.
        let never = try SensorCalibrationContract(sensorVariant: "warp19", sensorModelSHA256: modelHash, transform: .platt,
                                                  plattPayload: SensorPlattPayload(coef: 1, intercept: 0), decisionThreshold: 0.01, uncertainBand: 0.04)
        let cuts = never.equivalentCuts()
        #expect(cuts.realAtOrBelow == -1 && cuts.generatedAtOrAbove > 0.049 && cuts.generatedAtOrAbove < 0.051)
        let file = try #require(SensorCalibrationFile.twoCuts(from: never))
        let back = try SensorCalibrationContract.decode(try JSONCoding.prettyEncoder().encode(file), expectedModelSHA256: modelHash, expectedSensorVariant: "warp19")
        var differ = 0
        for n in 1...256 { for k in 0...n where back.prediction(for: Float(k) / Float(n)) != never.prediction(for: never.calibratedProbability(Float(k) / Float(n))) { differ += 1 } }
        #expect(differ == 0 && back.prediction(for: 0) == "inconclusive")
    }

    @Test("a cuts file is refused when its band is not its cuts', its cuts are out of order, or its schema is not 2")
    func cutsRefused() throws {
        func json(schema: Int = 2, calibration: String = "cuts", lo: Double = 0.7, hi: Double = 0.8, t: Double = 0.75, band: Double = 0.05,
                  comparison: String = "at_or_above_generated_cut") -> Data {
            Data("""
            {"schema_version": \(schema), "sensor_variant": "warp19", "sensor_model_sha256": "\(modelHash)",
             "score_semantics": "image_majority_fraction", "calibration": "\(calibration)", "platt_payload": null,
             "cuts": {"real_at_or_below": \(lo), "generated_at_or_above": \(hi)},
             "decision_threshold": \(t), "uncertain_band": \(band), "generated_comparison": "\(comparison)",
             "native_routes": ["camera"], "trust_law": "v1_decisive_native_capture_present_valid_and_governing_agreement"}
            """.utf8)
        }
        let ok = try SensorCalibrationContract.decode(json(), expectedModelSHA256: modelHash, expectedSensorVariant: "warp19")
        #expect(ok.prediction(for: 0.7) == "real" && ok.prediction(for: 0.75) == "inconclusive" && ok.prediction(for: 0.8) == "generated")
        for bad in [json(t: 0.76), json(band: 0.04), json(lo: 0.8, hi: 0.7, t: 0.75, band: -0.05), json(schema: 1),
                    json(comparison: "strictly_greater_than_threshold"), json(calibration: "identity")] {
            #expect(throws: SensorCalibrationError.self) { try SensorCalibrationContract.decode(bad, expectedModelSHA256: modelHash, expectedSensorVariant: "warp19") }
        }
    }

    @Test("the identity fallback keeps the raw fraction, an open band and Garde's provenance hash")
    func identityFallback() throws {
        let calibration = try SensorCalibrationContract.identityFallback(sensorVariant: "warp19", sensorModelSHA256: modelHash, uncertainBand: 0.25)
        #expect(calibration.identity == "identity-fallback")
        #expect(calibration.artifactSHA256 == nil)
        #expect(calibration.calibratedProbability(0.37) == 0.37)
        #expect(calibration.prediction(for: 0.50) == "inconclusive")
        #expect(calibration.prediction(for: 0.25) == "real")
        #expect(calibration.prediction(for: 0.75) == "generated")
        let campaign = try SensorCalibrationContract.identityFallback(sensorVariant: "warp19", sensorModelSHA256: modelHash, uncertainBand: 0.04)
        #expect(campaign.provenanceSHA256 == "2fc3428e1db2bb7a78e3b361febd1547098657be5634a106e34a39cf3fc2cf51")
    }

    @Test("Platt works on the logit scale")
    func plattScale() throws {
        let calibration = try SensorCalibrationContract(sensorVariant: "warp40", sensorModelSHA256: modelHash, transform: .platt,
                                                        plattPayload: SensorPlattPayload(coef: 2, intercept: 0), decisionThreshold: 0.7,
                                                        uncertainBand: 0.04, artifactSHA256: String(repeating: "b", count: 64))
        #expect(abs(calibration.calibratedProbability(0.8) - 16.0 / 17.0) < 1e-6)   // σ(2·logit 0.8)
        #expect(calibration.prediction(for: calibration.calibratedProbability(0.8)) == "generated")
    }

    @Test("decoding binds the exact model and variant")
    func decodeBinds() throws {
        let json = """
        {"schema_version": 1, "sensor_variant": "warp19_e16", "sensor_model_sha256": "\(modelHash)",
         "score_semantics": "image_majority_fraction", "calibration": "identity", "platt_payload": null,
         "decision_threshold": 0.61, "uncertain_band": 0.04, "generated_comparison": "strictly_greater_than_threshold",
         "native_routes": ["camera"], "trust_law": "v1_decisive_native_capture_present_valid_and_governing_agreement"}
        """
        let data = Data(json.utf8)
        let calibration = try SensorCalibrationContract.decode(data, expectedModelSHA256: modelHash, expectedSensorVariant: "warp19_e16")
        #expect(calibration.transform == .identity)
        #expect(abs(calibration.decisionThreshold - 0.61) < 1e-6)
        #expect(calibration.artifactSHA256?.count == 64)
        #expect(throws: SensorCalibrationError.self) {
            try SensorCalibrationContract.decode(data, expectedModelSHA256: String(repeating: "c", count: 64), expectedSensorVariant: "warp19_e16")
        }
        #expect(throws: SensorCalibrationError.variantMismatch(expected: "warp19_e16", actual: "warp40")) {
            try SensorCalibrationContract.decode(data, expectedModelSHA256: modelHash, expectedSensorVariant: "warp40")
        }
    }

    @Test("a written SensorCalibrationFile decodes as a valid contract")
    func fileForm() throws {
        let file = SensorCalibrationFile(sensorVariant: "warp19", sensorModelSHA256: modelHash, calibration: .platt,
                                         plattPayload: SensorPlattPayload(coef: 0.48908749922126266, intercept: -0.09094760943132153),
                                         decisionThreshold: 0.6298664647384551, uncertainBand: 0.04)
        let data = try JSONCoding.prettyEncoder().encode(file)
        let contract = try SensorCalibrationContract.decode(data, expectedModelSHA256: modelHash, expectedSensorVariant: "warp19")
        #expect(contract.transform == .platt && contract.plattPayload?.coef == 0.48908749922126266)
        let identity = SensorCalibrationFile(sensorVariant: "warp19", sensorModelSHA256: modelHash, calibration: .identity,
                                             plattPayload: nil, decisionThreshold: 0.5, uncertainBand: 0.04)
        let text = String(decoding: try JSONCoding.prettyEncoder().encode(identity), as: UTF8.self)
        #expect(text.contains("\"platt_payload\" : null"))
    }

    @Test("column counts name the sensor variants")
    func variants() throws {
        #expect(try SensorCalibrationContract.variant(featureCount: 19) == "warp19")
        #expect(try SensorCalibrationContract.variant(featureCount: 35) == "warp19_e16")
        #expect(try SensorCalibrationContract.variant(featureCount: 40) == "warp40")
        #expect(throws: SensorCalibrationError.self) { try SensorCalibrationContract.variant(featureCount: 12) }
    }
}
