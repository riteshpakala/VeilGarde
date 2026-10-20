//
//  CombinerTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The combiner's columns equal atlas_combiner.features, its bounded fit reaches scipy's
//        optimum, and the rescue sweep picks what the reference's picks: the fallback on the synthetic fit,
//        and the shipped 0.5 on the shipped weights.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeTraining

@Suite("Stack combiner")
struct CombinerTests {
    static func fixture() throws -> [String: Any] { try Fixture.json("combiner_fixture.json") }

    static func optional(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

    @Test("the feature columns equal the reference's")
    func features() throws {
        let f = try Self.fixture()
        let base = doubles(f["base"]), heads = (f["heads"] as! [[NSNumber]]).map { $0.map(\.doubleValue) }
        let pair = (f["pair"] as! [Any]).map(Self.optional), np = (f["np"] as! [Any]).map(Self.optional)
        let expected = (f["features"] as! [[NSNumber]]).map { $0.map(\.doubleValue) }
        for i in base.indices {
            let row = CombinerFeatures.row(base: base[i], heads: heads[i], pair: pair[i], noiseprint: np[i])
            #expect(maxAbs(row, expected[i]) < 1e-12, "row \(i)")
        }
    }

    @Test("a combiner fitted with no art-pair head does not adjudicate, and one fitted beside it does")
    func adjudication() throws {
        let f = try Self.fixture()
        let base = doubles(f["base"]), heads = (f["heads"] as! [[NSNumber]]).map { $0.map(\.doubleValue) }, y = ints(f["y"])
        let pair = (f["pair"] as! [Any]).map(Self.optional), np = (f["np"] as! [Any]).map(Self.optional)
        func samples(_ withPair: Bool) -> [CombinerSample] {
            base.indices.map { CombinerSample(id: "row\($0)", label: y[$0], base: base[$0], heads: heads[$0], pair: withPair ? pair[$0] : nil, noiseprint: np[$0]) }
        }
        let (alone, _) = try CombinerTrainer.train(samples(false))
        #expect(alone.pairAdjudicates == false && !alone.note.contains("art-pair"))
        #expect(try alone.combiner().pairAdjudicates == false)
        let (beside, _) = try CombinerTrainer.train(samples(true))
        #expect(beside.pairAdjudicates == true && beside.note.contains("art-pair"))
    }

    @Test("the bounded fit reaches scipy's optimum")
    func fit() throws {
        let f = try Self.fixture()
        let features = (f["features"] as! [[NSNumber]]).map { $0.map(\.doubleValue) }
        let y = ints(f["y"]), n = f["train"] as! Int
        let (w0, w) = CombinerTrainer.fitWeights(features: Array(features.prefix(n)), labels: Array(y.prefix(n)), realsWeight: 3)
        let tight = f["tight"] as! [String: Any]
        let tw = doubles(tight["w"])
        #expect(abs(w0 - double(tight["w0"])) < 1e-4)
        for j in [0, 1, 2, 3, 5] { #expect(abs(w[j] - tw[j]) < 1e-4, "w[\(j)] \(w[j]) vs \(tw[j])") }
        #expect(w[4] == 0)
        #expect(w.allSatisfy { $0 >= 0 })
    }

    @Test("the rescue sweep falls back to 1.0 when no weight keeps every probe real")
    func sweepFallback() throws {
        let f = try Self.fixture()
        let final = f["final"] as! [String: Any]
        var w = doubles(final["w"])
        w[4] = 0
        let (rescue, rows) = CombinerTrainer.chooseRescue(w0: double(final["w0"]), w: w, settings: CombinerSettings())
        #expect(rescue == 1.0)
        let expected = f["sweep"] as! [[String: Any]]
        for (row, e) in zip(rows, expected) {
            #expect(row.rescue == double(e["w_rescue"]))
            #expect(row.probesReal == e["user_reals_real"] as! Int)
            #expect(abs(row.maxProbe - double(e["max_p"])) < 1e-12)
        }
    }

    @Test("on the shipped weights the sweep picks the shipped 0.5")
    func sweepShipped() throws {
        let f = try Self.fixture()
        let w = [3.8205217946638634, 0.0, 0.0, 0.1966929563436263, 0.0, 0.8]
        let (rescue, rows) = CombinerTrainer.chooseRescue(w0: -0.6754975033517225, w: w, settings: CombinerSettings())
        #expect(rescue == double(f["deployed_chosen"]))
        #expect(rescue == 0.5)
        let expected = f["deployed_sweep"] as! [[String: Any]]
        for (row, e) in zip(rows, expected) {
            var ww = w
            ww[4] = row.rescue
            let mine = CombinerTrainer.probeScores(-0.6754975033517225, ww, CombinerProbe.userReals)
            for (name, p) in e["p"] as! [String: NSNumber] { #expect(abs(mine[name]! - p.doubleValue) < 1e-12, "probe \(name)") }
        }
        let shipped = try CombinerFile(w0: -0.6754975033517225, wBase: w[0], wGen: Array(w[1...3]), wRescue: rescue, wNp: w[5], note: "").combiner()
        #expect(shipped.wRescue == 0.5)
    }
}
