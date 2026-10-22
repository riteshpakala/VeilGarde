//
//  Show.swift
//  VeilGardeExamples
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: How the examples print: numbered step headers, and the checkpoints it collects for the
//        last step.
//

import Foundation
import VeilGarde

enum Show {
    static func step(_ n: Int, _ name: String, _ text: String) {
        print("\(String(n).padding(toLength: 3, withPad: " ", startingAt: 0))\(name.padding(toLength: 12, withPad: " ", startingAt: 0))\(text)")
    }

    static func line(_ text: String) { print("               " + text) }

    static func f(_ x: Float, _ digits: Int = 4) -> String { String(format: "%.\(digits)f", x) }
}

/// Every checkpoint the examples make, for the verify step and the exit code.
final class Checkpoints {
    private(set) var all: [(String, Bool)] = []

    func record(_ name: String, _ ok: Bool) {
        all.append((name, ok))
        Show.line("\(ok ? "✓" : "✗") \(name)")
    }

    var passed: Bool { all.allSatisfy(\.1) }
}
