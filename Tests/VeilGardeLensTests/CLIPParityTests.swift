//
//  CLIPParityTests.swift
//  VeilGardeLensTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The CLIP vision tower against Hugging Face's on the same pixels: every image's
//        embedding within cosine 0.9999, and the router's category call (the argmax over its
//        five prompts) the same. Skipped when the weights are not on this Mac.
//

import Foundation
import MLX
import Testing
import VeilGardeCore
@testable import VeilGardeLens

extension LensMLXSuites {
    @Suite("CLIP vision against Hugging Face", .serialized)
    struct CLIPParity {
        static let fixture = Fixture.url("clip_parity.safetensors")
        /// The work area's weights folder holds the tower (`veilgarde weights import-clip`).
        static var weights: URL? {
            if let area = WorkArea.resolve() { WeightLocator.shared.register(area.root.appendingPathComponent("weights", isDirectory: true)) }
            return WeightLocator.shared.url(.clipVision)
        }

        @Test("embeddings within cosine 0.9999 of HF's, categories equal", .enabled(if: weights != nil))
        func parity() throws {
            let f = try SafetensorsFile(url: Self.fixture)
            let pixels = try f.uint8("pixels"), expected = try f.float32("embeds"), logits = try f.float32("logits")
            let n = try f.tensor("pixels").shape[0]
            let ours = try CLIPLens.shared.tower()(CLIPPreprocess.input(pixels: pixels, count: n)).asArray(Float.self)
            let prompts = try SafetensorsFile(url: Fixture.repoRoot.appendingPathComponent("Sources/VeilGardeFlywheel/Resources/clip_prompts_v1.safetensors")).float32("prompts")
            for i in 0..<n {
                let a = Array(ours[(i * 512)..<((i + 1) * 512)]), b = Array(expected[(i * 512)..<((i + 1) * 512)])
                let cos = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                #expect(cos >= 0.9999, "image \(i): cosine \(cos)")
                let mine = (0..<5).map { k in 100 * zip(a, prompts[(k * 512)..<((k + 1) * 512)]).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
                let theirs = Array(logits[(i * 13)..<(i * 13 + 5)])
                #expect(mine.firstIndex(of: mine.max()!) == theirs.firstIndex(of: theirs.max()!), "image \(i): category")
            }
        }
    }
}
