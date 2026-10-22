//
//  Combiner.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The stack combiner as a recipe line, and how it trains: the store's capture-absent rows
//        scored by the candidate's camera head (the anchor) and its art, blur and human heads (the
//        evidence), CombinerTrainer's bounded fit, written as combiner/stack_combiner.json, the
//        version-1 file the combiner revision reads.
//
//            Combiner().realsWeight(3)
//
//  PIN:  It trains last: the camera head and the heads it reads are this recipe's when it trains
//        them, the parent's otherwise. The evidence is HeadKind.combinerOrder, in that order.
//

import Foundation
import VeilGardeCore

public struct Combiner: TrainableMember, Equatable {
    public static let recipeKind = "combiner"
    public var settings = CombinerSettings()

    public var name: String { "combiner" }
    public var rank: Int { 2 }

    public init() {}

    private func with(_ change: (inout Combiner) -> Void) -> Combiner { var c = self; change(&c); return c }
    public func realsWeight(_ w: Double) -> Combiner { with { $0.settings.realsWeight = w } }
    public func probes(_ p: [CombinerProbe]) -> Combiner { with { $0.settings.probes = p } }

    public func plan(in context: TrainingContext) throws -> ModelPlan {
        var p = ModelPlan(model: name, stages: [], refusal: context.storeMissing)
        let anchor = context.trains("camera") ? "the camera head this recipe trains" : "the parent's camera head"
        let evidence = HeadKind.combinerOrder.map { context.trains("head:\($0.rawValue)") ? "\($0.rawValue) (trained)" : "\($0.rawValue) (parent)" }
        p.stages = [
            StageDecision(.data, runs: true, "capture-absent store rows (not golden or NSFW): the anchor from \(anchor); evidence \(evidence.joined(separator: ", "))"),
            StageDecision(.fit, runs: true, "non-negative logistic, reals ×\(settings.realsWeight.formatted()), the rescue column zeroed"),
            StageDecision(.evaluate, runs: true, "the rescue sweep against \(settings.probes.count) protect-real probes; test AUC beside the camera head's"),
            StageDecision(.write, runs: true, "combiner/stack_combiner.json"),
        ]
        return p
    }

    public func train(in run: TrainingRun) throws -> String {
        run.emit(.stage(model: name, .data))
        guard let cameraURL = run.candidate.url(.camera) else { throw VeilGardeFailure.missing("the candidate has no camera head") }
        let camera = try GBDTModel.load(cameraURL)
        let heads = try HeadKind.combinerOrder.map { kind -> LinearHead in
            guard let url = run.candidate.url(.head, head: kind) else { throw VeilGardeFailure.missing("the candidate has no \(kind.rawValue) head") }
            return try LinearHead.load(url)
        }
        let selection = try run.store.select(columns: Set(FeatureColumn.allCases)) { !$0.golden && !$0.nsfw }
        let samples = try CombinerSample.captureAbsent(selection, camera: camera, heads: heads)
        run.emit(.stage(model: name, .fit))
        let (file, report) = try CombinerTrainer.train(samples, evidence: HeadKind.combinerOrder.map(\.rawValue), settings: settings,
                                                       note: { run.emit(.note($0)) })
        run.emit(.stage(model: name, .evaluate))
        run.emit(.note(String(format: "combiner: w0 %.3f, anchor %.3f, evidence [%@], rescue %.1f", file.w0, file.anchor.w,
                              file.evidence.map { String(format: "%@ %.3f", $0.member, $0.w) }.joined(separator: ", "), file.rescue.w)))
        run.emit(.stage(model: name, .write))
        try run.candidate.put(try JSONCoding.prettyEncoder().encode(file), as: "combiner/stack_combiner.json", role: .combiner)
        return try run.record(report, model: name, as: "combiner/metrics.json")
    }
}
