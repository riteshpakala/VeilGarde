//
//  VerdictTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The three-state label's open band at the camera member's operating point, and the camera
//        head's 393-column order: DINOv2 then the nine capture values.
//

import Foundation
import Testing
@testable import VeilGardeCore

@Suite("Verdict and the camera row")
struct VerdictTests {
    @Test("the band is open and generated is strictly above the threshold")
    func labels() {
        let rule = DecisionRule.camera
        #expect(rule.threshold == 0.5 && rule.band == 0.04)
        #expect(rule.label(0.5) == "inconclusive")
        #expect(rule.label(0.53) == "inconclusive")
        #expect(rule.label(0.54) == "generated")   // exactly the band edge is decisive
        #expect(rule.label(0.45) == "real")
        #expect(rule.label(0.9) == "generated")
    }

    @Test("the camera row keeps its trained column order: DINOv2 (384), then capture (9)")
    func featureOrder() throws {
        let capture = CaptureFeatures(vector: [42, 1, 1, 1024, 3, 0.4, 0.5, 0.1, 0.2])
        #expect(capture.signature == CaptureSignature(peak: 42, valid: true, nativePixels: 1024, present: true))
        let row = CameraRow(dino: [Float](repeating: 0.5, count: 384), capture: capture)
        let flat = row.asVector
        #expect(flat.count == 393 && CameraRow.width == 393)
        #expect(flat[0] == 0.5 && flat[383] == 0.5 && flat[384] == 42 && flat[387] == 1024 && flat[392] == 0.2)
        #expect(CameraRow.names.count == 393 && CameraRow.names[384] == "cap_" + CaptureFeatures.names[0])
        #expect(CameraRow.columns == [.dinoFusion, .cap] && CameraRow.columns.map(\.width).reduce(0, +) == CameraRow.width)
    }
}
