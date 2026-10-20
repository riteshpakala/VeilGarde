//
//  VeilGardeFailure.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: One error type the CLI prints and maps to sysexits, so scripts can branch on the code:
//        1 doctor or battery failure, 3 parity mismatch, 64 usage, 65 data, 66 missing input,
//        69 unavailable, 70 internal, 73 exists, 75 temporary, 78 configuration, 130 interrupted.
//  PIN:  Braid's table (itself RaoLM's), so the family's scripts read the same codes. Named
//        FailureCode, not ExitCode, so the CLI never has to qualify ArgumentParser's.
//

import Foundation

public enum FailureCode: Int32, Sendable {
    case ok = 0
    case doctor = 1
    case parityMismatch = 3
    case usage = 64
    case data = 65
    case missingInput = 66
    case unavailable = 69
    case internalError = 70
    case exists = 73
    case temporary = 75
    case configuration = 78
    case interrupted = 130
}

public struct VeilGardeFailure: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var hint: String?
    public var code: FailureCode

    public init(_ message: String, hint: String? = nil, code: FailureCode) {
        self.message = message
        self.hint = hint
        self.code = code
    }

    public var description: String { hint.map { "\(message)\n  \($0)" } ?? message }

    public static func usage(_ message: String, hint: String? = nil) -> VeilGardeFailure { VeilGardeFailure(message, hint: hint, code: .usage) }
    public static func data(_ message: String, hint: String? = nil) -> VeilGardeFailure { VeilGardeFailure(message, hint: hint, code: .data) }
    public static func missing(_ message: String, hint: String? = nil) -> VeilGardeFailure { VeilGardeFailure(message, hint: hint, code: .missingInput) }
    public static func unavailable(_ message: String, hint: String? = nil) -> VeilGardeFailure { VeilGardeFailure(message, hint: hint, code: .unavailable) }
    public static func exists(_ message: String, hint: String? = nil) -> VeilGardeFailure { VeilGardeFailure(message, hint: hint, code: .exists) }
    public static func temporary(_ message: String, hint: String? = nil) -> VeilGardeFailure { VeilGardeFailure(message, hint: hint, code: .temporary) }
    public static func configuration(_ message: String, hint: String? = nil) -> VeilGardeFailure { VeilGardeFailure(message, hint: hint, code: .configuration) }
    public static func internalError(_ message: String, hint: String? = nil) -> VeilGardeFailure { VeilGardeFailure(message, hint: hint, code: .internalError) }
}
