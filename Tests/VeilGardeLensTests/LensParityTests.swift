//
//  LensParityTests.swift
//  VeilGardeLensTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The warp lens against Garde and the Python reference: the 256 × 19 tile feature matrix of each parity crop
//        equals Garde's --dump-features output byte for byte, and the directional signature meets
//        Garde's tolerances on the v4_a1_tilesig fixture. GPU suites, one at a time.
//

import Foundation
import Testing
@testable import VeilGardeLens

extension LensMLXSuites {
    @Suite("Lens parity with Garde and the Python reference", .serialized)
    struct LensParityTests {
        @Test("the tile feature matrix equals Garde's dump byte for byte", arguments: ["crop_ben", "crop_fox"])
        func featureDump(name: String) throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.garde("\(name).png"))
            let (map, geometry) = try WarpLens.tileFeatures(cgImage: cg)
            #expect(map.tileRows == 16 && map.tileCols == 16 && map.featureCount == 19)
            #expect(geometry.scoringWidth == 512 && geometry.scoringHeight == 512)
            let ours = try map.dumpJSON(patchRows: 16, patchCols: 16, tilesPerPatch: 1)
            let garde = try Data(contentsOf: Fixture.url("\(name).features.json"))
            #expect(ours == garde, "\(name): the dumps differ")
            if ours != garde {
                let a = try JSONSerialization.jsonObject(with: ours) as! [String: Any], b = try JSONSerialization.jsonObject(with: garde) as! [String: Any]
                let fa = (a["features"] as! [[NSNumber]]).flatMap { $0.map(\.doubleValue) }, fb = (b["features"] as! [[NSNumber]]).flatMap { $0.map(\.doubleValue) }
                Issue.record("max |Δ feature| \(zip(fa, fb).map { abs($0 - $1) }.max() ?? -1)")
            }
        }

        @Test("the directional signature meets Garde's tolerances on the reference fixture")
        func directionalSignature() throws {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: Fixture.url("dirsig_fixture.json"))) as! [String: Any]
            let h = (object["height"] as! NSNumber).intValue, w = (object["width"] as! NSNumber).intValue
            let img = (object["image"] as! [NSNumber]).map(\.floatValue), sig = (object["sig"] as! [NSNumber]).map(\.floatValue)
            let got = WarpDebug.directionalSignature(imageRGB: img, height: h, width: w, quantizeLikeCV2: true)
            var raw: Float = 0, derived: Float = 0
            for t in 0..<((h / 32) * (w / 32)) {
                for f in 0..<21 {
                    let d = abs(got[t * 21 + f] - sig[t * 21 + f])
                    if f < 16 { raw = max(raw, d) } else { derived = max(derived, d) }
                }
            }
            #expect(raw < 1e-3, "raw energies max |Δ| \(raw)")
            #expect(derived < 5e-3, "log-ratios max |Δ| \(derived)")
        }
    }
}
