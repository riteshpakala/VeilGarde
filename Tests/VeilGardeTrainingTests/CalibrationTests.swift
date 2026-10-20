//
//  CalibrationTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Platt reaches sklearn's optimum on tile-vote fractions (and sits within 2e-3 of the
//        reference lbfgs fit), choose_operating_threshold is reproduced exactly, and the trainer's contract
//        decodes under the strict validator bound to the sensor model's hash.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeTraining

@Suite("Sensor calibration")
struct CalibrationTests {
    @Test("Platt on the calibration partition matches sklearn")
    func platt() throws {
        let f = try Fixture.json("platt_fixture.json")
        let frac = doubles(f["frac"]), y = ints(f["y"]), calib = ints(f["calibration"])
        let fit = Platt.fit(labels: calib.map { y[$0] }, probabilities: calib.map { frac[$0] })
        let tight = f["tight"] as! [String: Any], reference = f["reference"] as! [String: Any]
        #expect(abs(fit.coef - double(tight["coef"])) < 1e-6)
        #expect(abs(fit.intercept - double(tight["intercept"])) < 1e-6)
        #expect(abs(fit.coef - double(reference["coef"])) < 2e-3)
        #expect(abs(fit.intercept - double(reference["intercept"])) < 2e-3)
    }

    @Test("the operating threshold is choose_operating_threshold's")
    func threshold() throws {
        let f = try Fixture.json("platt_fixture.json")
        let y = ints(f["y"]), held = ints(f["threshold_partition"])
        let selected = doubles(f["tight_selected"])
        let choice = try OperatingThreshold.choose(labels: held.map { y[$0] }, probabilities: selected, maxRealFPR: 0.10)
        let expected = f["tight_operating"] as! [String: Any]
        #expect(choice.threshold == double(expected["threshold"]))
        #expect(choice.generatedRecall == double(expected["validation_generated_recall"]))
        #expect(throws: VeilGardeFailure.self) { try OperatingThreshold.choose(labels: [0, 0], probabilities: [0.9, 0.95], maxRealFPR: -1) }
    }

    @Test("the trainer's contract decodes bound to the sensor model")
    func contract() throws {
        let f = try Fixture.json("platt_fixture.json")
        let frac = doubles(f["frac"]), y = ints(f["y"])
        let samples = frac.indices.map { CalibrationTrainer.Sample(key: "img\($0)", label: y[$0], fraction: frac[$0]) }
        let sha = String(repeating: "ab", count: 32)
        let (file, report) = try CalibrationTrainer.fit(samples, sensorModelSHA256: sha, sensorVariant: "warp19")
        let data = try JSONCoding.prettyEncoder().encode(file)
        let contract = try SensorCalibrationContract.decode(data, expectedModelSHA256: sha, expectedSensorVariant: "warp19")
        #expect(contract.transform == report.calibration)
        #expect(abs(Double(contract.decisionThreshold) - report.operating.threshold) < 1e-6)
        #expect(contract.uncertainBand == 0.04)
        #expect(report.fitImages.values.allSatisfy { $0 >= 25 })
        #expect(report.crossFitFolds == 5)
        #expect(throws: (any Error).self) { try SensorCalibrationContract.decode(data, expectedModelSHA256: String(repeating: "cd", count: 32), expectedSensorVariant: "warp19") }
    }
}
