//
//  Pipeline.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The detector as one declaration: Decode → Shared Signals → Stack → Revisions → Result.
//        The caller decodes; the pipeline computes the signals once, runs every member of its
//        stack, runs its revisions in order, and returns one result that lists every member's
//        output and every revision's record. `Pipeline.v1` is the shipped detector.
//  PIN:  Stacking, not blending: each member keeps its own score in the result, and the combiner
//        pools only the evidence members it names around one anchor; a monolithic combiner
//        regressed real false positives 8% → 50–92% in the research's measurement, the stack
//        holds them at 0%. Routing is never by image size. The training recipe declares the
//        trainable members the same way (TrainingRecipe).
//

import CoreGraphics

public struct Pipeline: Sendable {
    public let stack: Stack
    public let revisions: Revisions

    public init(stack: Stack, revisions: Revisions) {
        self.stack = stack
        self.revisions = revisions
    }

    public init(@PipelineBuilder _ content: () -> (Stack, Revisions)) {
        let parts = content()
        self.stack = parts.0
        self.revisions = parts.1
    }

    /// The shipped detector, v1.
    public static var v1: Pipeline {
        Pipeline {
            Stack {
                Screenshot()
                Camera()
                Capture()
                Specialist(.art)
                Specialist(.blur)
                Specialist(.human)
                Specialist(.preview)
                SemanticTiles()
            }
            Revisions {
                Combine()
                FrameSeam()
                PreviewTail()
            }
        }
    }

    /// Shared Signals → Stack → Revisions → Result, for one decoded image.
    public func run(cgImage: CGImage, config: InferenceConfig) throws -> InferenceResult {
        let signals = DetectionSignals(cgImage: cgImage, config: config)
        let outputs = try stack.score(signals)
        var verdict = WorkingVerdict(p: 0.5, prediction: "inconclusive", threshold: config.decision.threshold, band: config.decision.band)
        var records: [RevisionRecord] = []
        for revision in revisions.steps {
            records.append(try revision.apply(&verdict, stack: outputs, signals: signals, pipeline: self))
        }
        return InferenceResult(prediction: verdict.prediction, p: verdict.p, threshold: verdict.threshold, band: verdict.band,
                               imageWidth: signals.width, imageHeight: signals.height, stack: outputs, revisions: records,
                               bundle: config.bundle.hashes)
    }
}

@resultBuilder
public enum PipelineBuilder {
    public static func buildBlock(_ stack: Stack, _ revisions: Revisions) -> (Stack, Revisions) { (stack, revisions) }
}
