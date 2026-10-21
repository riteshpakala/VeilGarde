//
//  VerdictTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The three-state label's open band at the detector's one operating point, and the fusion
//        head's 393-column order: DINOv2 then the nine capture values.
//

import Foundation
import Testing
@testable import VeilGardeCore

@Suite("Verdict and the fusion row")
struct VerdictTests {
    @Test("the band is open and generated is strictly above the threshold")
    func labels() {
        let rule = DecisionRule.fusion
        #expect(rule.threshold == 0.5 && rule.band == 0.04)
        #expect(rule.label(0.5) == "inconclusive")
        #expect(rule.label(0.53) == "inconclusive")
        #expect(rule.label(0.54) == "generated")   // exactly the band edge is decisive
        #expect(rule.label(0.45) == "real")
        #expect(rule.label(0.9) == "generated")
    }

    @Test("the fusion row keeps its trained column order: DINOv2 (384), then capture (9)")
    func featureOrders() throws {
        let capture = CaptureFeatures(vector: [42, 1, 1, 1024, 3, 0.4, 0.5, 0.1, 0.2])
        #expect(capture.signature == CaptureSignature(peak: 42, valid: true, nativePixels: 1024, present: true))
        let vector = FusionVector(dino: [Float](repeating: 0.5, count: 384), capture: capture)
        let flat = vector.asVector
        #expect(flat.count == 393 && FusionVector.count == 393)
        #expect(flat[0] == 0.5 && flat[383] == 0.5 && flat[384] == 42 && flat[387] == 1024 && flat[392] == 0.2)
        #expect(FusionVector.names.count == 393 && FusionVector.names[384] == "cap_" + CaptureFeatures.names[0])
        #expect(FusionLayout.dinoCapture.columns == [.dinoFusion, .cap] && FusionLayout.dinoCapture.width == FusionVector.count)
        #expect(vector.layout == .dinoCapture)
    }

    @Test("both DINOv2 readings make a 777-column row: the plain CLS, the force-resized one, then capture; a head's width names its layout")
    func bothReadings() throws {
        let capture = CaptureFeatures(vector: [42, 1, 1, 1024, 3, 0.4, 0.5, 0.1, 0.2])
        let vector = FusionVector(dino: [Float](repeating: 0.5, count: 384), dinoNorm: [Float](repeating: -1, count: 384), capture: capture)
        let flat = vector.asVector
        #expect(vector.layout == .bothReadings && flat.count == 777 && FusionLayout.bothReadings.width == 777)
        #expect(flat[383] == 0.5 && flat[384] == -1 && flat[767] == -1 && flat[768] == 42 && flat[776] == 0.2)
        #expect(FusionLayout.bothReadings.columns == [.dinoFusion, .dinoNorm, .cap])
        let names = FusionLayout.bothReadings.names
        #expect(names.count == 777 && names[384] == "dnorm0" && names[768] == "cap_" + CaptureFeatures.names[0])
        #expect(try FusionLayout.of(width: 393) == .dinoCapture && FusionLayout.of(width: 777) == .bothReadings)
        #expect(throws: VeilGardeFailure.self) { try FusionLayout.of(width: 397) }
    }
}
