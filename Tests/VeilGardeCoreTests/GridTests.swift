//
//  GridTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The weight map, the weighted verdict and sharpness against float32 replicas of Garde's
//        loops (written once from the Python reference); the three-state label's open band; the grid.
//

import Foundation
import Testing
@testable import VeilGardeCore

@Suite("Grid and verdict")
struct GridTests {
    @Test("weight map, weighted score and sharpness match the float32 replica")
    func weightMap() throws {
        let reference = try Fixture.json("weightmap_reference.json")
        for case let c as [String: Any] in reference["cases"] as! [Any] {
            let patch = (c["patch"] as! [[NSNumber]]).map { $0.map(\.floatValue) }
            let tex = (c["tex"] as! [[NSNumber]]).map { $0.map(\.floatValue) }
            let expected = (c["weights"] as! [[NSNumber]]).map { $0.map(\.floatValue) }
            let weights = WeightMap.build(patchGrid: patch, texWeights: tex, parameters: WeightMapParameters())
            let worst = zip(weights.flatMap { $0 }, expected.flatMap { $0 }).map { abs($0 - $1) }.max() ?? 0
            #expect(worst < 1e-6, "\(patch.count)×\(patch[0].count): max |Δw| \(worst)")
            let score = WeightedVerdict.score(patchGrid: patch, weightMap: weights, hotspot: HotspotRule())
            #expect(abs(score - float(c["score"])!) < 1e-6)
            let sharp = SharpnessFeatures.measure(texWeights: tex, weightMap: weights)
            #expect(abs(sharp.salientSharp - float(c["salient"])!) < 1e-4)
            #expect(abs(sharp.globalSharp - float(c["global"])!) < 1e-4)
            #expect(abs(sharp.sharpRatio - float(c["ratio"])!) < 1e-5)
        }
    }

    @Test("hotspot off is the plain weighted mean")
    func hotspotOff() {
        let p: [[Float]] = [[0.9, 0.1]], w: [[Float]] = [[0.5, 0.5]]
        #expect(WeightedVerdict.score(patchGrid: p, weightMap: w, hotspot: HotspotRule(mode: .off)) == 0.5)
        // Symmetric: both patches are confident, mean 0.5, so the blend keeps 0.5.
        #expect(abs(WeightedVerdict.score(patchGrid: p, weightMap: w, hotspot: HotspotRule()) - 0.5) < 1e-7)
        // Asymmetric: only 0.9 pulls, up.
        #expect(WeightedVerdict.score(patchGrid: p, weightMap: w, hotspot: HotspotRule(mode: .asymmetric)) > 0.5)
    }

    @Test("the band is open and generated is strictly above the threshold")
    func labels() {
        let rule = DecisionRule.warpWeighted
        #expect(rule.label(0.56) == "inconclusive")
        #expect(rule.label(0.60) == "generated")   // exactly the band edge is decisive
        #expect(rule.label(0.52) == "real")
        #expect(rule.label(0.61) == "generated")
        #expect(DecisionRule.fusion.label(0.53) == "inconclusive")
    }

    @Test("a tile grid indexes row-major and returns its rows")
    func tileGrid() {
        var grid = TileGrid(rows: 2, cols: 3, values: [1, 2, 3, 4, 5, 6] as [Float])
        #expect(grid[1, 0] == 4)
        grid[0, 2] = 9
        #expect(grid.rowsArray == [[1, 2, 9], [4, 5, 6]])
        #expect(TileGrid([[1, 2], [3, 4]] as [[Float]]).values == [1, 2, 3, 4])
    }

    @Test("the feature vectors keep their trained column orders")
    func featureOrders() throws {
        let row = (0..<19).map(Float.init)
        let features = try WarpFeatures(vector: row)
        #expect(features.asVector == row)
        #expect(features.fr == 0 && features.nyqR == 18 && features.cfaG == 11 && features.noiseRatio == 16)
        #expect(WarpFeatures.names.count == 19 && WarpFeatures.name(ofColumn: 18) == "nyq_R")
        let capture = CaptureFeatures(vector: [42, 1, 1, 1024, 3, 0.4, 0.5, 0.1, 0.2])
        #expect(capture.signature == CaptureSignature(peak: 42, valid: true, nativePixels: 1024, present: true))
        let vector = FusionVector(warp: 0.7, dino: [Float](repeating: 0.5, count: 384), capture: capture,
                                  sharpness: SharpnessFeatures(salientSharp: 10, globalSharp: 5, sharpRatio: 2))
        let flat = vector.asVector
        #expect(flat.count == 397 && FusionVector.count == 397)
        #expect(flat[0] == 0.7 && flat[385] == 42 && flat[388] == 1024 && flat[394] == 10 && flat[396] == 2)
        #expect(FusionVector.names.count == 397)
    }
}
