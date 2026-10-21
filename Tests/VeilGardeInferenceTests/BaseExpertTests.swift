//
//  BaseExpertTests.swift
//  VeilGardeInferenceTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The camera base expert's switch. By default it is the fusion head, and rebinding a config
//        to another bundle reads that bundle's warp pair and calibration. On the GPU, the warp lens
//        alone as the base hands the stack the lens's own weighted verdict, names itself "warp",
//        and leaves the sensor lane, the patch map and the capture signature byte for byte the
//        fusion base's; both carry the lens's own score, and the JSON never writes it.
//

import Foundation
import Testing
@testable import VeilGardeInference

@Suite("The camera base expert")
struct BaseExpertTests {
    @Test("the detector's default is the fusion head, and rebinding reads another bundle's models")
    func defaults() {
        #expect(InferenceConfig().baseExpert == .fusion && InferenceConfig.shipped.baseExpert == .fusion)
        var config = InferenceConfig()
        let elsewhere = DetectorBundle(directory: URL(fileURLWithPath: "/tmp/elsewhere", isDirectory: true), manifest: ShippedBundle.manifest)
        config.rebind(to: elsewhere)
        #expect(config.bundle == elsewhere && config.modelURL.path.hasPrefix("/tmp/elsewhere/"))
        #expect(config.majoritySensorModelURL?.path.hasPrefix("/tmp/elsewhere/") == true && config.sensorCalibrationURL?.path.hasPrefix("/tmp/elsewhere/") == true)
        #expect(DetectorBundle.shipped.provenance["weighted_base_model_sha256"] == ShippedBundle.manifest.artifact(.warpTile)?.sha256)
        #expect(BaseExpert(rawValue: "warp") == .warp && BaseExpert.allCases.count == 2)
    }
}

extension InferenceMLXSuites {
    @Suite("The warp lens as the camera base", .serialized, .enabled(if: Fixture.weightsPresent))
    struct WarpBaseTests {
        @Test("the warp base keeps the sensor lane, names itself, and the stack compounds on the lens's own score")
        func warpBase() throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.garde("crop_ben.png"))
            let fused = try Detector.shared.detect(cgImage: cg, config: InferenceConfig())
            var config = InferenceConfig()
            config.baseExpert = .warp
            let warped = try Detector.shared.detect(cgImage: cg, config: config)
            let lens = try WarpInference.run(cgImage: cg, config: InferenceConfig())
            let f = fused.result, w = warped.result
            func near(_ a: Float?, _ b: Float) -> Bool { a.map { abs($0 - b) < 1e-6 } ?? false }
            #expect(w.scorer == "warp" && f.scorer == "fusion")
            #expect(w.specialists?.first?.name == "warp" && near(w.specialists?.first?.pAI, lens.weightedScore))
            #expect(near(w.routeDiagnostics?.warpP, lens.weightedScore) && !near(f.routeDiagnostics?.warpP, lens.weightedScore))
            #expect(w.decisionThreshold == 0.56 && w.uncertainBand == 0.04)
            #expect(w.sensorRawProbability == f.sensorRawProbability && w.sensorPrediction == f.sensorPrediction)
            #expect(w.majorityPrediction == f.majorityPrediction && w.majorityScore == f.majorityScore)
            #expect(w.patches.map(\.pGenerated) == f.patches.map(\.pGenerated) && w.captureSignature?.peak == f.captureSignature?.peak)
            #expect(near(f.warpWeightedScore, lens.weightedScore) && near(w.warpWeightedScore, lens.weightedScore))
            let json = try ResultJSON.encode(f, times: [], device: "route", route: "camera")
            var bare = f
            bare.warpWeightedScore = nil
            let bareJSON = try ResultJSON.encode(bare, times: [], device: "route", route: "camera")
            #expect(json == bareJSON, "the lens's own score is never encoded")
            let object = try JSONSerialization.jsonObject(with: try ResultJSON.encode(w, times: [], device: "route", route: "camera")) as? [String: Any]
            #expect(object?["scorer"] as? String == "warp")
        }
    }
}
