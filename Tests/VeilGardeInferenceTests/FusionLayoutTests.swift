//
//  FusionLayoutTests.swift
//  VeilGardeInferenceTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The detector builds the fusion row in the layout its head's width names: a 777-column
//        head reads the force-resized DINOv2 embedding after the plain one, and a 393-column head
//        reads the capture values there. Each head is one hand-built tree split on one column, at
//        a threshold between what the two layouts would put in that column, inside a copy of the
//        shipped bundle.
//

import Foundation
import Testing
@testable import VeilGardeInference

extension InferenceMLXSuites {
    @Suite("Fusion layouts", .serialized, .enabled(if: Fixture.weightsPresent))
    struct FusionLayoutTests {
        /// One tree: −2 when `column` is under `threshold`, +2 otherwise, from a base score of 0.5.
        static func oneSplit(on column: Int, at threshold: Float, width: Int) -> GBDTModel {
            let tree = GBDTModel.Tree(id: 0, leftChildren: [1, -1, -1], rightChildren: [2, -1, -1], parents: [GBDTModel.Tree.rootParent, 0, 0],
                                      splitIndices: [Int32(column), 0, 0], splitConditions: [threshold, -2, 2], baseWeights: [0, -2, 2],
                                      defaultLeft: [0, 0, 0], splitType: [0, 0, 0], lossChanges: [1, 0, 0], sumHessian: [10, 5, 5], numFeature: width)
            return GBDTModel(trees: [tree], baseScoreProbability: 0.5, featureCount: width)
        }

        /// The shipped bundle, copied, with its fusion head replaced and the manifest re-pinned.
        static func bundle(with head: GBDTModel) throws -> (DetectorBundle, URL) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vg-layout-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var manifest = ShippedBundle.manifest
            for a in manifest.artifacts where a.role != .fusionHead {
                try FileManager.default.copyItem(at: ShippedBundle.directory.appendingPathComponent(a.file), to: dir.appendingPathComponent(a.file))
            }
            try head.encodeXGBoostJSON().write(to: dir.appendingPathComponent("fusion_head.xgb.json"))
            manifest.artifacts.removeAll { $0.role == .fusionHead }
            manifest.artifacts.append(try ModelBundle.record(.fusionHead, file: "fusion_head.xgb.json", in: dir))
            try JSONCoding.write(manifest, to: dir.appendingPathComponent(BundleManifest.fileName))
            return (try DetectorBundle.load(dir), dir)
        }

        @Test("each head's row is built in its own layout: column 384 is dino_norm's first value at 777 columns, capture's at 393")
        func layouts() throws {
            let cg = try ImageDecoding.cgImage(contentsOf: Fixture.crop("crop_fox.png"))
            let norm = try SemanticLens.normalizedEmbedding(cg)[0], cap = CaptureLens.features(cg).asVector[0]
            #expect(norm != cap)
            for (layout, right, wrong) in [(FusionLayout.bothReadings, norm, cap), (.dinoCapture, cap, norm)] {
                let threshold = (right + wrong) / 2
                let (bundle, dir) = try Self.bundle(with: Self.oneSplit(on: 384, at: threshold, width: layout.width))
                defer { try? FileManager.default.removeItem(at: dir) }
                let base = try #require(Detector.shared.detect(cgImage: cg, config: InferenceConfig(bundle: bundle)).result.routeDiagnostics?.baseP)
                let want: Float = right < threshold ? 1 / (1 + Float(exp(2.0))) : 1 / (1 + Float(exp(-2.0)))
                #expect(abs(base - want) < 1e-6, "\(layout.rawValue): base \(base), want \(want)")
            }
        }
    }
}
