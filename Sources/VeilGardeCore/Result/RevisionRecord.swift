//
//  RevisionRecord.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What one revision did to the verdict: its name, whether it changed anything, the P(AI) and
//        the prediction it left, and the fields only it reports (the combiner's anchor and each
//        member's pull, the frame seam's interior score, the preview tail's gates).
//  PIN:  The revisions run in the pipeline's order after the stack; each record holds the verdict as
//        that revision left it, so the last record's p and prediction are the result's.
//

public struct RevisionRecord: Sendable, Equatable {
    public let name: String
    /// The revision changed the verdict (the combiner, which sets it, always applies).
    public let applied: Bool
    public let p: Float
    public let prediction: String
    public let fields: [Field]

    public init(name: String, applied: Bool, p: Float, prediction: String, fields: [Field] = []) {
        self.name = name
        self.applied = applied
        self.p = p
        self.prediction = prediction
        self.fields = fields
    }

    public subscript(key: String) -> Detail? { fields.first { $0.key == key }?.value }

    public func number(_ key: String) -> Float? { if case .number(let v)? = self[key] { return v } else { return nil } }
    public func flag(_ key: String) -> Bool? { if case .flag(let v)? = self[key] { return v } else { return nil } }
    public func text(_ key: String) -> String? { if case .text(let v)? = self[key] { return v } else { return nil } }
}

public extension Array where Element == RevisionRecord {
    /// The record of that revision, when it ran.
    func revision(_ name: String) -> RevisionRecord? { first { $0.name == name } }
}
