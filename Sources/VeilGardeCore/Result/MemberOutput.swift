//
//  MemberOutput.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What one member of the stack says about an image: its name, its own P(AI) (nil for a
//        member that measures rather than scores, such as the capture signature), its verdict, and
//        the fields only it reports. Every member reads the shared signals and nothing else, so the
//        stack is a flat list of independent takes on where the image came from.
//  PIN:  The result JSON writes a member as {"name", "p", "verdict", …its fields}; a field may not
//        reuse those three keys. Field values are numbers, flags, text, a grid or a map of numbers,
//        or absent (written as null, so a key stays stable from image to image).
//

/// One value a member or a revision reports beside its p and verdict.
public enum Detail: Sendable, Equatable {
    case number(Float)
    case flag(Bool)
    case text(String)
    case grid([[Float]])
    case map([String: Float])
    case absent
}

/// A named value in a member's or a revision's output.
public struct Field: Sendable, Equatable {
    public let key: String
    public let value: Detail

    public init(_ key: String, _ value: Detail) {
        precondition(!["name", "p", "verdict", "applied", "prediction"].contains(key), "\(key) is one of the output's own keys")
        self.key = key
        self.value = value
    }
}

/// What one stack member said about the image.
public struct MemberOutput: Sendable, Equatable {
    public let name: String
    /// Its own P(AI); nil when the member measures without scoring.
    public let p: Float?
    public let verdict: String
    public let fields: [Field]

    public init(name: String, p: Float?, verdict: String, fields: [Field] = []) {
        self.name = name
        self.p = p
        self.verdict = verdict
        self.fields = fields
    }

    public subscript(key: String) -> Detail? { fields.first { $0.key == key }?.value }

    public func number(_ key: String) -> Float? { if case .number(let v)? = self[key] { return v } else { return nil } }
    public func flag(_ key: String) -> Bool? { if case .flag(let v)? = self[key] { return v } else { return nil } }
    public func text(_ key: String) -> String? { if case .text(let v)? = self[key] { return v } else { return nil } }
    public func grid(_ key: String) -> [[Float]]? { if case .grid(let v)? = self[key] { return v } else { return nil } }
}

public extension Array where Element == MemberOutput {
    /// The member of that name, when the stack holds it.
    func member(_ name: String) -> MemberOutput? { first { $0.name == name } }
}
