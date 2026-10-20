//
//  WarpGoldenTests.swift
//  VeilGardeInferenceTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The shipped bundle verifies and the config defaults point into it, the sensor pair
//        included; and the warp lens's result JSON for each parity crop is Garde's
//        (Garde's headless `<crop> --json -`, 2026-10-19), every leaf exactly equal apart from
//        times_sec and the sensor fields the two cuts changed on purpose, whose call is Garde's.
//

import Foundation
import Testing
@testable import VeilGardeInference

@Suite("Shipped bundle")
struct ShippedBundleTests {
    @Test("the shipped bundle verifies and the defaults point into it")
    func defaults() throws {
        let bundle = try ShippedBundle.verified()
        #expect(bundle.manifest.artifacts.count == 14)
        #expect(bundle.manifest.artifact(.head, head: .artPair) == nil, "the art-pair head left the bundle with its adjudicator")
        let config = InferenceConfig()
        #expect(config.modelURL.lastPathComponent == "warp_tile32.xgb.json")
        #expect(config.majoritySensorModelURL?.lastPathComponent == "warp_majority_tile32.xgb.json")
        #expect(config.sensorCalibrationURL?.lastPathComponent == "warp_sensor_calibration.json")
        #expect(config.decision == .warpWeighted && config.warp.patchSize == 32 && config.warp.maxDim == 512 && config.warp.quantizeLikeCV2)
        #expect(config.mechanisms.semanticResponsibility == .control && config.mechanisms.resultSurface == .warpSensor)
        #expect(!config.mechanisms.zoomEscalation && !config.mechanisms.renderTaxonomy && !config.mechanisms.xDomainGate)
    }

    @Test("the shipped sensor and calibration are a bound pair")
    func sensorPair() throws {
        let sha = try ArtifactHashCache.shared.sha256(ShippedBundle.url(.warpMajoritySensor))
        let contract = try SensorCalibrationContract.decode(Data(contentsOf: ShippedBundle.url(.sensorCalibration)), expectedModelSHA256: sha, expectedSensorVariant: "warp19")
        #expect(contract.transform == .cuts && contract.nativeRoutes == ["camera"])
    }
}

extension InferenceMLXSuites {
    @Suite("Warp lens goldens from Garde", .serialized)
    struct WarpGoldenTests {
        @Test("the warp result JSON equals Garde's for the parity crops", arguments: ["crop_ben", "crop_fox"])
        func warpJSON(name: String) throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.garde("\(name).png"))
            let result = try WarpInference.run(cgImage: cg, config: InferenceConfig())
            let ours = try ResultJSON.encode(result, times: [], device: "gpu")
            let (worst, mismatches) = try compare(ours, Data(contentsOf: Fixture.garde("\(name).score.json")), tolerance: 0)
            #expect(mismatches.isEmpty && worst == 0, "\(mismatches.prefix(5))")
            #expect(result.sensorProbability == result.sensorRawProbability && result.sensorCalibration?.transform == .cuts)
        }
    }
}
