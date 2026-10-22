//
//  TileFeatureTests.swift
//  VeilWatermarkTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: warp19 as detection reads it: the 19 tile features of each parity crop equal the
//        research's tile extractor's dump value for value; the residual statistics are each
//        feature's mean, then its spread, over those tiles; and, when the work area's final_mixed
//        tiles are on disk, one capped and padded image equals its research tiles.
//

import Foundation
import Testing
@testable import VeilWatermark

extension WatermarkMLXSuites {
    @Suite("warp19 on the GPU", .serialized)
    struct TileFeatureTests {
        @Test("each crop's 19 tile features equal the research's dump, value for value", arguments: ["crop_ben", "crop_fox"])
        func dump(name: String) throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.crop("\(name).png"))
            let plane = try TilePlane(cg)
            #expect(plane.paddedWidth == 512 && plane.paddedHeight == 512)
            let rows = TileFeatures.measure(plane)
            let dump = try Fixture.tileDump(name)
            #expect(rows.tileRows == 16 && rows.tileCols == 16 && dump.feature_order == ResidualStatistics.features)
            let want = dump.features.flatMap { $0.map(Float.init) }
            let worst = zip(rows.values, want).map { abs($0 - $1) }.max() ?? .infinity
            #expect(rows.values == want, "\(name): max |Δ| \(worst)")
        }

        @Test("the statistics are each feature's mean, then its population spread, over the tiles")
        func statistics() throws {
            let dump = try Fixture.tileDump("crop_fox")
            let rows = TileFeatureRows(tileRows: 16, tileCols: 16, values: dump.features.flatMap { $0.map(Float.init) })
            let stats = ResidualStatistics.summarize(rows)
            #expect(stats.count == 38 && ResidualStatistics.count == 38)
            for k in 0..<19 {
                let v = dump.features.map { Double(Float($0[k])) }
                let mean = v.reduce(0, +) / Double(v.count)
                let spread = (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count)).squareRoot()
                #expect(abs(Double(stats[k]) - mean) <= 1e-6 * max(1, abs(mean)), "\(ResidualStatistics.features[k]) mean")
                #expect(abs(Double(stats[19 + k]) - spread) <= 1e-5 * max(1, spread), "\(ResidualStatistics.features[k]) spread")
            }
        }

        static let finalMixedTiles = URL(fileURLWithPath: "/Volumes/T9/rao/projects/veilgarde/store/tiles/final_mixed/tiles_0000")

        @Test("a final_mixed image, capped and padded, equals its research tiles",
              .enabled(if: FileManager.default.fileExists(atPath: finalMixedTiles.path + ".images.json")))
        func researchTiles() throws {
            struct Image: Decodable { let path: String; let start: Int; let rows: Int; let cols: Int }
            let images = try JSONDecoder().decode([Image].self, from: Data(contentsOf: URL(fileURLWithPath: Self.finalMixedTiles.path + ".images.json")))
            let shard = try SafetensorsFile(url: URL(fileURLWithPath: Self.finalMixedTiles.path + ".tiles.safetensors"))
            let all = try shard.float32("features")
            for image in images.prefix(2) {
                let url = URL(fileURLWithPath: "/Volumes/T9/datasets/final_mixed").appendingPathComponent(image.path)
                let rows = TileFeatures.measure(try TilePlane(try ImageDecoding.cgImage(contentsOf: url)))
                #expect(rows.tileRows == image.rows && rows.tileCols == image.cols)
                let want = Array(all[(image.start * 19)..<((image.start + image.rows * image.cols) * 19)])
                let worst = zip(rows.values, want).map { abs($0 - $1) }.max() ?? .infinity
                #expect(worst <= 1e-4, "\(image.path): max |Δ| \(worst)")
            }
        }
    }
}
