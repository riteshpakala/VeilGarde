//
//  Revision.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The Revisions stage: after every member has spoken, the revisions read the stack's
//        outputs in order and revise one working verdict, each recording what it did. The first
//        sets the verdict (the combiner); the rest act only on decisive evidence (the frame seam,
//        the preview tail). A new revision is one file that conforms to Revision and one line in
//        a pipeline.
//
//            Revisions {
//                Combine()
//                FrameSeam()
//            }
//
//  PIN:  Before the first revision the verdict is inconclusive at 0.5 under the config's rule; a
//        pipeline without a revision that sets it says so. A revision reads members by name and
//        refuses a stack that lacks one it needs.
//

/// The verdict as the revisions carry it.
public struct WorkingVerdict: Sendable, Equatable {
    public var p: Float
    public var prediction: String
    public var threshold: Float
    public var band: Float

    public init(p: Float, prediction: String, threshold: Float, band: Float) {
        self.p = p
        self.prediction = prediction
        self.threshold = threshold
        self.band = band
    }
}

public protocol Revision: Sendable {
    /// The revision's name in the result.
    var name: String { get }
    /// Revises the verdict from the stack's outputs and returns what it did.
    func apply(_ verdict: inout WorkingVerdict, stack: [MemberOutput], signals: DetectionSignals, pipeline: Pipeline) throws -> RevisionRecord
}

public struct Revisions: Sendable {
    public let steps: [any Revision]

    public init(@RevisionBuilder _ content: () -> [any Revision]) {
        self.steps = content()
    }
}

@resultBuilder
public enum RevisionBuilder {
    public static func buildExpression(_ revision: some Revision) -> [any Revision] { [revision] }
    public static func buildExpression(_ revisions: [any Revision]) -> [any Revision] { revisions }
    public static func buildBlock(_ parts: [any Revision]...) -> [any Revision] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [any Revision]?) -> [any Revision] { part ?? [] }
    public static func buildEither(first part: [any Revision]) -> [any Revision] { part }
    public static func buildEither(second part: [any Revision]) -> [any Revision] { part }
    public static func buildArray(_ parts: [[any Revision]]) -> [any Revision] { parts.flatMap { $0 } }
}

extension Array where Element == MemberOutput {
    /// The member a revision needs, or a failure naming it.
    func required(_ name: String, by revision: String) throws -> MemberOutput {
        guard let m = member(name) else {
            throw VeilGardeFailure.data("the \(revision) revision reads the \(name) member, which the stack does not hold")
        }
        return m
    }
}
