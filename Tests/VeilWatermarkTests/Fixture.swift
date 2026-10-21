//
//  Fixture.swift
//  VeilWatermarkTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Paths the watermark tests read by repo path: the two 512-px parity crops; the fragility
//        rate each yields at phase (0, 0) with its signature's content id, pinned on 2026-10-21
//        before the residual moved, so the move is held to exactly the numbers it started from; and
//        each crop's 19 tile features as the research's tile extractor dumped them.
//

import Foundation

enum Fixture {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "Tests" { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent()
    }()

    /// A parity crop (crop_ben.png, crop_fox.png).
    static func crop(_ name: String) -> URL {
        repoRoot.appendingPathComponent("Tests/VeilGardeInferenceTests/Fixtures/crops/\(name)")
    }

    /// The pinned fragility of one crop.
    struct Fragility: Decodable {
        let image: String
        let rows: Int
        let cols: Int
        let cid: String
        let fr: [Double]
    }

    static func fragility(_ name: String) throws -> Fragility {
        let url = repoRoot.appendingPathComponent("Tests/VeilWatermarkTests/Fixtures/\(name).fr.json")
        return try JSONDecoder().decode(Fragility.self, from: Data(contentsOf: url))
    }

    /// The research's 19 tile features of one crop, 256 tiles row-major, as its tile extractor
    /// dumped them (restored from the 2026-rnd branch's lens parity fixtures).
    struct TileDump: Decodable {
        let feature_order: [String]
        let features: [[Double]]
    }

    static func tileDump(_ name: String) throws -> TileDump {
        let url = repoRoot.appendingPathComponent("Tests/VeilWatermarkTests/Fixtures/\(name).features.json")
        return try JSONDecoder().decode(TileDump.self, from: Data(contentsOf: url))
    }
}
