//
//  PythonRandomTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The CPython `random.Random` port draws Python's exact sequences: 32- and 64-bit words,
//        random(), randrange and shuffle, for small and multi-word seeds.
//

import Foundation
import Testing
@testable import VeilGardeTraining

@Suite("CPython random")
struct PythonRandomTests {
    @Test("every recorded sequence matches CPython 3.12")
    func sequences() throws {
        let cases = try Fixture.json("python_random.json")["cases"] as! [[String: Any]]
        #expect(cases.count == 5)
        for c in cases {
            let seed = UInt64(c["seed"] as! String)!
            var r = PythonRandom(seed: seed)
            #expect((0..<6).map { _ in Int(r.getrandbits(32)) } == ints(c["bits32"]), "seed \(seed)")
            r = PythonRandom(seed: seed)
            #expect((0..<6).map { _ in r.random() } == doubles(c["random"]), "seed \(seed)")
            r = PythonRandom(seed: seed)
            var a = Array(0..<10), b = Array(0..<37)
            r.shuffle(&a); r.shuffle(&b)
            #expect(a == ints(c["shuffle10"]), "seed \(seed)")
            #expect(b == ints(c["shuffle37"]), "seed \(seed)")
            r = PythonRandom(seed: seed)
            let bounds = (c["randbelow_n"] as! [String]).map { Int($0)! }
            #expect(bounds.map { r.randbelow($0) } == (c["randbelow"] as! [String]).map { Int($0)! }, "seed \(seed)")
            r = PythonRandom(seed: seed)
            #expect((0..<3).map { _ in r.getrandbits(64) } == (c["bits64"] as! [String]).map { UInt64($0)! }, "seed \(seed)")
        }
    }
}
