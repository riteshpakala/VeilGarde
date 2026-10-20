//
//  FlywheelInvariantsTests.swift
//  VeilGardeFlywheelTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The flywheel's laws on a fixture work area: init seeds live once; a promote moves exactly
//        its slot behind the battery and logs it; a failed battery restores live byte for byte; a
//        rollback returns live to the snapshot byte for byte; the frozen artifacts never move; the
//        base moves only by a warm start of the live head; a calibration must be bound to the live
//        sensor; an atlas head must pass admission; training and measuring never write live/.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeFlywheel

@Suite("Flywheel invariants", .serialized)
struct FlywheelInvariantsTests {
    static func candidate(_ f: FlywheelFixture, id: String = "cand", @TrainingBuilder _ models: () -> [ModelRecipe]) throws -> URL {
        let engine = TrainingEngine(area: f.area.area, parent: f.area.live, store: f.area.store)
        return try engine.train(TrainingRecipe(id: id, models: models())).candidate.root
    }

    static func frozen(_ live: ModelBundle) -> [String: String] {
        Dictionary(uniqueKeysWithValues: live.manifest.artifacts.filter(\.frozen).map { ($0.slot, $0.sha256) })
    }

    @Test("init seeds live from the shipped bundle once")
    func initOnce() throws {
        let f = try FlywheelFixture()
        let live = try f.area.liveBundle()
        #expect(live.manifest.artifacts == (try ModelBundle.load(Fixture.resources)).manifest.artifacts)
        #expect(live.manifest.history.last?.kind == .seed)
        #expect(throws: VeilGardeFailure.self) { try f.area.initialize(from: try ModelBundle.load(Fixture.resources), spec: Data(), baseline: Data()) }
    }

    @Test("a promote moves its slot behind the battery; frozen artifacts never move; rollback restores live byte for byte")
    func promoteAndRollback() throws {
        let f = try FlywheelFixture()
        let before = try f.area.liveHashes()
        let frozenBefore = Self.frozen(try f.area.liveBundle())
        let root = try Self.candidate(f) {
            FusionHead().warmStart(add: 2, eta: 0.03)
            DinoHead(.human)
        }
        #expect(try f.area.liveHashes() == before, "training never writes live/")
        let promoter = Promoter(area: f.area, battery: f.battery)
        let record = try promoter.promote(.head(.human), from: root, store: FeatureStore(directory: f.area.store))
        #expect(record.kind == .promote && record.battery == "PASS")
        let live = try f.area.liveBundle()
        let human = try #require(live.manifest.artifact(.head, head: .human))
        #expect(human.file == "human_dinov2_cand.json" && human.source == "candidates/cand")
        #expect(human.sha256 == (try ModelBundle.load(root)).sha256(.head, head: .human))
        #expect(Self.frozen(live) == frozenBefore)
        #expect(live.manifest.history.last?.kind == .promote)

        let base = try promoter.promote(.base, from: root, store: nil)
        #expect(base.kind == .promote)
        let shippedFusion = try ModelBundle.load(Fixture.resources).sha256(.fusionHead)
        #expect(try f.area.liveBundle().manifest.artifact(.fusionHead)?.parent == shippedFusion, "the base records the head it continues")
        #expect(Self.frozen(try f.area.liveBundle()) == frozenBefore)

        // Back to before the head promote: two rollbacks (the base, then the head).
        try promoter.rollback()
        let afterOne = try f.area.liveHashes()
        #expect(afterOne != before)
        let first = promoter.snapshots().first { !$0.hasSuffix("before-rollback") }!
        try promoter.rollback(to: first)
        #expect(try f.area.liveHashes() == before, "rollback restores live byte for byte")
        let log = try String(contentsOf: f.area.promoteLog, encoding: .utf8).split(separator: "\n")
        #expect(log.count == 4)
    }

    @Test("a failed battery restores live byte for byte")
    func failedBattery() throws {
        let f = try FlywheelFixture()
        let root = try Self.candidate(f) { DinoHead(.human) }
        let before = try f.area.liveHashes()
        f.fail()
        #expect(throws: VeilGardeFailure.self) { try Promoter(area: f.area, battery: f.battery).promote(.head(.human), from: root, store: FeatureStore(directory: f.area.store)) }
        #expect(try f.area.liveHashes() == before)
        let last = try String(contentsOf: f.area.promoteLog, encoding: .utf8).split(separator: "\n").last!
        #expect(last.contains("\"kind\":\"failed\""))
    }

    @Test("frozen slots, a cold base, an unbound calibration and a blocking head are refused before live moves")
    func refusals() throws {
        let f = try FlywheelFixture()
        for name in ["warp-tile", "fusion-reference", "noiseprint", "dinov2-small"] {
            #expect(throws: VeilGardeFailure.self) { try FlywheelSlot(parsing: name) }
        }
        let before = try f.area.liveHashes()
        let promoter = Promoter(area: f.area, battery: f.battery)
        let cold = try Self.candidate(f, id: "cold") { FusionHead().scratch(trees: 3, eta: 0.1) }
        #expect(throws: VeilGardeFailure.self) { try promoter.promote(.base, from: cold) }

        // A calibration bound to another sensor model, and a head that fires on every calm real.
        var c = try CandidateBundle.open(cold)
        let unbound = SensorCalibrationFile(sensorVariant: "warp19", sensorModelSHA256: String(repeating: "cd", count: 32), calibration: .identity,
                                            plattPayload: nil, decisionThreshold: 0.5, uncertainBand: 0.04)
        try c.put(try JSONCoding.prettyEncoder().encode(unbound), as: "calibration/warp_sensor_calibration.json", role: .sensorCalibration)
        #expect(throws: (any Error).self) { try promoter.promote(.calibration, from: cold) }
        let shipped = try LinearHead.load(Fixture.resources.appendingPathComponent("human_dinov2_v4.json"))
        let blocking = HeadFile(model: "human_dinov2", scalerMean: shipped.mean.map(Double.init), scalerScale: shipped.scale.map(Double.init),
                                coef: [Double](repeating: 0, count: 384), intercept: 9)
        try c.put(try JSONCoding.prettyEncoder().encode(blocking), as: "heads/human/head.json", role: .head, head: .human)
        #expect(throws: VeilGardeFailure.self) { try promoter.promote(.head(.human), from: cold, store: FeatureStore(directory: f.area.store)) }
        #expect(throws: VeilGardeFailure.self) { try promoter.promote(.head(.human), from: cold, store: nil) }
        #expect(try f.area.liveHashes() == before)
        let refused = try String(contentsOf: f.area.promoteLog, encoding: .utf8).split(separator: "\n").filter { $0.contains("\"kind\":\"refused\"") }
        #expect(refused.count == 4)
    }

    @Test("the weekly candidates and the agreement read live and never write it")
    func weekly() throws {
        let f = try FlywheelFixture()
        let before = try f.area.liveHashes()
        var recipe = WeeklyCandidates.recipe(id: "weekly-test")
        recipe.models = recipe.models.map { m in
            if case .fusion(let fusion) = m { return .fusion(fusion.warmStart(add: 2, eta: 0.03)) }
            return m
        }
        let outcome = try WeeklyCandidates.run(recipe, area: f.area)
        #expect(try f.area.liveHashes() == before)
        let review = try String(contentsOf: outcome.review, encoding: .utf8)
        #expect(review.contains("## The decision rule") && review.contains("veilgarde flywheel promote"))
        #expect(outcome.liveAgreement.rows > 0 && (0...1).contains(outcome.liveAgreement.agreementAll))
        let csv = try String(contentsOf: f.area.metricsCSV, encoding: .utf8).split(separator: "\n")
        #expect(csv.count == 3 && csv[0].hasPrefix("date,fusion,corpus_n,agreement_all"))
        #expect(Agreement.domain("/data/final_mixed/real/x.jpg") == "camera")
        #expect(Agreement.domain("/data/atlas/anchors/art/real/a_shot.jpg") == "processed")
        #expect(Agreement.domain("/pools/art/1.jpg") == "other")
    }
}
