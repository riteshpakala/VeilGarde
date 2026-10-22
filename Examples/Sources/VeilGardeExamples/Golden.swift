//
//  Golden.swift
//  VeilGardeExamples
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Comparing a result JSON with VeilGarde's own golden: every label exact and every number
//        within a tolerance, times_sec aside.
//

import Foundation
import VeilGarde

enum Golden {
    static func leaves(_ value: Any, _ path: String = "") -> [(String, Any)] {
        if let d = value as? [String: Any] { return d.keys.sorted().flatMap { leaves(d[$0]!, path.isEmpty ? $0 : "\(path).\($0)") } }
        if let a = value as? [Any] { return a.enumerated().flatMap { leaves($1, "\(path)[\($0)]") } }
        return [(path, value)]
    }

    static func compare(_ a: Data, _ b: Data, tolerance: Double) throws -> (worst: Double, mismatches: [String]) {
        let kept: ((String, Any)) -> Bool = { !$0.0.hasPrefix("times_sec") }
        let x = Dictionary(uniqueKeysWithValues: leaves(try JSONSerialization.jsonObject(with: a)).filter(kept))
        let y = Dictionary(uniqueKeysWithValues: leaves(try JSONSerialization.jsonObject(with: b)).filter(kept))
        var worst = 0.0
        var mismatches = Array(Set(x.keys).symmetricDifference(y.keys)).sorted()
        for key in Set(x.keys).intersection(y.keys) {
            if let m = x[key] as? NSNumber, let n = y[key] as? NSNumber, CFGetTypeID(m) != CFBooleanGetTypeID() {
                let d = abs(m.doubleValue - n.doubleValue)
                worst = max(worst, d)
                if d > tolerance { mismatches.append(key) }
            } else if "\(x[key]!)" != "\(y[key]!)" {
                mismatches.append(key)
            }
        }
        return (worst, mismatches)
    }
}
