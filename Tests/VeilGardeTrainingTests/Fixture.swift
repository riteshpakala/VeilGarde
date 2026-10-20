//
//  Fixture.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Paths the training tests read: their committed fixtures (written once from the Python
//        reference) and the shipped bundle's resources, by repo path.
//

import Foundation
import VeilGardeCore

enum Fixture {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "Tests" { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent()
    }()

    static let resources = repoRoot.appendingPathComponent("Sources/VeilGardeInference/Resources")

    static func resource(_ name: String) -> URL { resources.appendingPathComponent(name) }

    static func url(_ name: String) -> URL { repoRoot.appendingPathComponent("Tests/VeilGardeTrainingTests/Fixtures/\(name)") }

    static func json(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url(name))) as! [String: Any]
    }

    static func tensors(_ name: String) throws -> SafetensorsFile { try SafetensorsFile(url: url(name)) }

}

func floats(_ any: Any?) -> [Float] { (any as? [NSNumber])?.map { $0.floatValue } ?? [] }
func doubles(_ any: Any?) -> [Double] { (any as? [NSNumber])?.map { $0.doubleValue } ?? [] }
func ints(_ any: Any?) -> [Int] { (any as? [NSNumber])?.map { $0.intValue } ?? [] }
func double(_ any: Any?) -> Double { (any as? NSNumber)?.doubleValue ?? .nan }
func maxAbs(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).map { abs($0 - $1) }.max() ?? 0 }
