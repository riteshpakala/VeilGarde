//
//  Show.swift
//  VeilGardePlayground
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: How the playground prints: numbered step headers, a compact P(generated) map, and the
//        checkpoints it collects for the last step.
//

import Foundation
import VeilGarde

enum Show {
    static func step(_ n: Int, _ name: String, _ text: String) {
        print("\(String(n).padding(toLength: 3, withPad: " ", startingAt: 0))\(name.padding(toLength: 12, withPad: " ", startingAt: 0))\(text)")
    }

    static func line(_ text: String) { print("               " + text) }

    /// The sensor map as two-digit percentages, every second row and column for a 16×16 grid.
    static func map(_ r: InferenceResult) {
        let stride = r.gridCols > 12 ? 2 : 1
        for i in Swift.stride(from: 0, to: r.gridRows, by: stride) {
            var row = ""
            for j in Swift.stride(from: 0, to: r.gridCols, by: stride) {
                let p = r.patches[i * r.gridCols + j].pGenerated
                row += String(format: "%3.0f", p * 100)
            }
            line(row)
        }
    }

    static func f(_ x: Float, _ digits: Int = 4) -> String { String(format: "%.\(digits)f", x) }
}

/// Every checkpoint the playground makes, for the verify step and the exit code.
final class Checkpoints {
    private(set) var all: [(String, Bool)] = []

    func record(_ name: String, _ ok: Bool) {
        all.append((name, ok))
        Show.line("\(ok ? "✓" : "✗") \(name)")
    }

    var passed: Bool { all.allSatisfy(\.1) }
}
