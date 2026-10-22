//
//  Stack.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The Stack stage: a flat list of members, each an independent take on the image. A member
//        reads only the shared signals and says what it sees in its own output: its P(AI), its
//        verdict, its own fields. No member reads another's output; that is the Revisions stage's
//        job. A new member is one file that conforms to StackMember and one line in a pipeline.
//
//            Stack {
//                Camera()
//                Specialist(.art)
//            }
//
//  PIN:  Members run in the declared order and the result lists them in it. A member that has
//        nothing to say for this bundle or profile (its head is not in the bundle, the profile
//        removed it) returns nil and has no entry.
//

public protocol StackMember: Sendable {
    /// The member's name in the result.
    var name: String { get }
    /// What the member sees in the image, or nil when it has nothing to say.
    func score(_ s: DetectionSignals) throws -> MemberOutput?
}

public struct Stack: Sendable {
    public let members: [any StackMember]

    public init(@StackBuilder _ content: () -> [any StackMember]) {
        self.members = content()
    }

    /// Every member's output, in order.
    public func score(_ s: DetectionSignals) throws -> [MemberOutput] {
        try members.compactMap { try $0.score(s) }
    }
}

@resultBuilder
public enum StackBuilder {
    public static func buildExpression(_ member: some StackMember) -> [any StackMember] { [member] }
    public static func buildExpression(_ members: [any StackMember]) -> [any StackMember] { members }
    public static func buildBlock(_ parts: [any StackMember]...) -> [any StackMember] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [any StackMember]?) -> [any StackMember] { part ?? [] }
    public static func buildEither(first part: [any StackMember]) -> [any StackMember] { part }
    public static func buildEither(second part: [any StackMember]) -> [any StackMember] { part }
    public static func buildArray(_ parts: [[any StackMember]]) -> [any StackMember] { parts.flatMap { $0 } }
}
