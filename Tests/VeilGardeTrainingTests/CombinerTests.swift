//
//  CombinerTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The combiner's five columns equal the reference's first five (atlas_combiner.features;
//        the sixth, the noiseprint's, left on 2026-10-21) wherever the art-pair head did not move
//        the art logit, the bounded solver reaches scipy's optimum on the reference fit, the
//        rescue sweep follows its rule, on the shipped combiner's own weights no candidate passes,
//        so the sweep falls back to the shipped 1.0, and a fit writes the version-1 file keyed by
//        member.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeTraining

@Suite("Stack combiner")
struct CombinerTests {
    static func fixture() throws -> [String: Any] { try Fixture.json("combiner_fixture.json") }

    static func optional(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

    @Test("the five feature columns equal the reference's first five where no art-pair moved the art logit")
    func features() throws {
        let f = try Self.fixture()
        let base = doubles(f["base"]), heads = (f["heads"] as! [[NSNumber]]).map { $0.map(\.doubleValue) }
        let pair = (f["pair"] as! [Any]).map(Self.optional)
        let expected = (f["features"] as! [[NSNumber]]).map { $0.map(\.doubleValue) }
        var checked = 0
        for i in base.indices {
            if let p = pair[i], CombinerFeatures.logit(p, cap: CombinerFeatures.capHead) < CombinerFeatures.logit(heads[i][0], cap: CombinerFeatures.capHead) { continue }
            checked += 1
            let row = CombinerFeatures.row(camera: base[i], heads: heads[i])
            #expect(row.count == CombinerFeatures.count && CombinerFeatures.count == 5)
            #expect(maxAbs(row, Array(expected[i].prefix(5))) < 1e-12, "row \(i)")
        }
        #expect(checked > 500)
    }

    @Test("a fit writes the version-1 file: the camera anchor, the evidence keyed by member")
    func file() throws {
        let f = try Self.fixture()
        let base = doubles(f["base"]), heads = (f["heads"] as! [[NSNumber]]).map { $0.map(\.doubleValue) }, y = ints(f["y"])
        let samples = base.indices.map { CombinerSample(id: "row\($0)", label: y[$0], camera: base[$0], heads: heads[$0]) }
        let (file, report) = try CombinerTrainer.train(samples)
        #expect(file.version == 1 && file.evidence.map(\.member) == ["art", "blur", "human"] && file.anchor.cap == 4 && file.evidenceCap == 2)
        #expect(file.anchor.w >= 0 && file.evidence.allSatisfy { $0.w >= 0 } && file.rescue.w == report.rescue)
        #expect(report.fitted.count == 1 + CombinerFeatures.count && report.testAUCCamera != nil)
        let c = try file.combiner()
        #expect(c.evidenceMembers == ["art", "blur", "human"])
    }

    @Test("the bounded solver reaches scipy's optimum on the reference's six-column fit")
    func fit() throws {
        let f = try Self.fixture()
        let features = (f["features"] as! [[NSNumber]]).map { $0.map(\.doubleValue) }
        let y = ints(f["y"]), n = f["train"] as! Int
        var flat = [Double]()
        for row in features.prefix(n) { var r = row; r[4] = 0; flat += r }
        let theta = BoundedLogistic.fit(f: flat, y: y.prefix(n).map(Double.init), m: 6, sampleWeight: y.prefix(n).map { $0 == 0 ? 3 : 1 })
        let tight = f["tight"] as! [String: Any]
        let tw = doubles(tight["w"])
        #expect(abs(theta[0] - double(tight["w0"])) < 1e-4)
        for j in [0, 1, 2, 3, 5] { #expect(abs(theta[1 + j] - tw[j]) < 1e-4, "w[\(j)] \(theta[1 + j]) vs \(tw[j])") }
        #expect(theta.dropFirst().allSatisfy { $0 >= 0 })
    }

    /// The sweep's rule, restated: the first nonzero candidate under which every probe reads at or
    /// under 0.5 and none above 0.42, else the fallback.
    func expectedRescue(w0: Double, w: [Double], settings: CombinerSettings) -> Double {
        for candidate in settings.rescueSweep where candidate != 0 {
            var ww = w
            ww[4] = candidate
            let scores = CombinerTrainer.probeScores(w0, ww, settings.probes)
            if scores.values.allSatisfy({ $0 <= 0.5 }) && (scores.values.max() ?? 0) <= settings.maxProbe { return candidate }
        }
        return settings.rescueFallback
    }

    @Test("the rescue sweep follows its rule on the reference fit and on the research's weights")
    func sweep() throws {
        let f = try Self.fixture()
        let final = f["final"] as! [String: Any]
        var fitted = Array(doubles(final["w"]).prefix(5))
        fitted[4] = 0
        let settings = CombinerSettings()
        #expect(CombinerTrainer.chooseRescue(w0: double(final["w0"]), w: fitted, settings: settings).rescue
                == expectedRescue(w0: double(final["w0"]), w: fitted, settings: settings))
        // The research's v1.9.7 weights without the noiseprint: probe 3 reads 0.409 at rescue 0.5, under the 0.42 bar.
        let research = [3.8205217946638634, 0.0, 0.0, 0.1966929563436263, 0.0]
        let (rescue, rows) = CombinerTrainer.chooseRescue(w0: -0.6754975033517225, w: research, settings: settings)
        #expect(rescue == 0.5 && rows.count == settings.rescueSweep.count)
    }

    @Test("on the shipped combiner's own weights no sweep candidate passes, and the fallback is the shipped rescue")
    func sweepShipped() throws {
        let c = try StackCombiner.load(Fixture.resource("stack_combiner.json"))
        let w = [Double(c.anchor.w)] + c.evidence.map { Double($0.w) } + [0]
        let settings = CombinerSettings()
        let (rescue, sweep) = CombinerTrainer.chooseRescue(w0: Double(c.w0), w: w, settings: settings)
        #expect(!sweep.contains { $0.probesReal == settings.probes.count && $0.maxProbe <= settings.maxProbe })
        #expect(rescue == settings.rescueFallback && rescue == Double(c.rescue.w))
    }
}
