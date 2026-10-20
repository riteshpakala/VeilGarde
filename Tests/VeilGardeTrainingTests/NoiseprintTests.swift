//
//  NoiseprintTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The noiseprint trainer. On the CPU: the reference split (disjoint, seeded, three to one per
//        family), the patch sampler (seeded, blank patches dropped, bytes equal to the gray
//        plane), the recompression levels (JPEG and HEIC on this Mac), the recipe table and the
//        engine's plan. On the GPU: a trained-form net and its folded file compute the same
//        P(camera); the Bayar projection holds; the shipped net loads into the trained form and
//        folds back to its own bytes; and a few epochs on toy patches lower the loss.
//

import CoreGraphics
import Foundation
import MLX
import MLXNN
import Testing
import VeilGardeCore
import VeilGardeLens
@testable import VeilGardeTraining

enum NoiseprintFixture {
    /// An RGB image whose pixel (x, y) is `value(x, y)` in 0…255 on every channel.
    static func image(width: Int, height: Int, _ value: (Int, Int) -> UInt8) -> CGImage {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width { let v = value(x, y); px[(y * width + x) * 4] = v; px[(y * width + x) * 4 + 1] = v; px[(y * width + x) * 4 + 2] = v } }
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    static func noise(width: Int, height: Int, seed: UInt64) -> CGImage {
        var rng = SplitMix64(seed: seed)
        return image(width: width, height: height) { _, _ in UInt8(truncatingIfNeeded: rng.next() >> 56) }
    }

    /// A folder of empty files with image extensions (listing never decodes).
    static func folder(_ root: URL, _ name: String, count: Int) throws -> String {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for i in 0..<count { FileManager.default.createFile(atPath: dir.appendingPathComponent(i % 3 == 0 ? "sub/img_\(i).png" : "img_\(i).jpg").path, contents: Data()) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("._img_0.jpg").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("notes.txt").path, contents: Data())
        return dir.path
    }

    static func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("veilgarde-noiseprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("Noiseprint trainer: data")
struct NoiseprintDataTests {
    @Test("the reference split: camera then each family from one seeded stream, disjoint, three to one")
    func split() throws {
        let root = try NoiseprintFixture.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        var sources = NoiseprintSources(camera: try NoiseprintFixture.folder(root, "camera", count: 12),
                                        negatives: [NoiseprintFamily("a", try NoiseprintFixture.folder(root, "a", count: 10)),
                                                    NoiseprintFamily("b", try NoiseprintFixture.folder(root, "b", count: 6)),
                                                    NoiseprintFamily("empty", root.appendingPathComponent("nowhere").path)])
        sources.cameraTrain = 8
        sources.perFamily = 8
        let s = try sources.split()
        #expect(NoiseprintSources.list(sources.camera).count == 12, "resource forks and other files are left out; subfolders are walked")
        #expect(s.cameraTrain.count == 8 && s.cameraTest.count == 4)
        #expect(Set(s.cameraTrain).isDisjoint(with: s.cameraTest))
        #expect(s.counts["a"] == [10, 6, 2] && s.counts["b"] == [6, 6, 0] && s.counts["empty"] == [0, 0, 0])
        #expect(s.negativeTrain.count == 12)
        #expect(s.negativeTest.map(\.family) == ["a", "b", "empty"])
        #expect(try sources.split() == s, "the same folders and seed give the same split")
        var reseeded = sources
        reseeded.seed = 1
        #expect(try reseeded.split() != s)
        var tooFew = sources
        tooFew.cameraTrain = 12
        #expect(throws: VeilGardeFailure.self) { try tooFew.split() }
    }

    @Test("an excluded file leaves every folder, by path and by content, and a family added last keeps the others' splits")
    func exclusion() throws {
        let root = try NoiseprintFixture.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        func folder(_ name: String, count: Int) throws -> String {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<count { try Data("\(name)-\(i)".utf8).write(to: dir.appendingPathComponent("img_\(i).jpg")) }
            return dir.path
        }
        let camera = try folder("camera", count: 12), a = try folder("a", count: 10), forged = try folder("forged", count: 8)
        let anchor = forged + "/img_3.jpg"
        try FileManager.default.copyItem(atPath: anchor, toPath: a + "/copy_of_anchor.jpg")
        var before = NoiseprintSources(camera: camera, negatives: [NoiseprintFamily("a", a)])
        before.cameraTrain = 8
        before.perFamily = 8
        var after = before
        after.negatives.append(NoiseprintFamily("forged", forged))
        let s = try after.split(excluding: [anchor])
        #expect(s.excluded.map { URL(fileURLWithPath: $0).lastPathComponent } == ["copy_of_anchor.jpg", "img_3.jpg"], "the copy under another name goes too")
        #expect(s.counts["a"] == [10, 6, 2] && s.counts["forged"] == [7, 6, 1])
        let every = s.cameraTrain + s.cameraTest + s.negativeTrain + s.negativeTest.flatMap(\.urls)
        #expect(!every.contains { $0.lastPathComponent == "copy_of_anchor.jpg" || $0.path.hasSuffix("/forged/img_3.jpg") })
        let first = try before.split(excluding: [anchor])
        #expect(s.cameraTrain == first.cameraTrain && s.cameraTest == first.cameraTest && s.negativeTest[0].urls == first.negativeTest[0].urls,
                "a family appended last does not move the families before it")
        #expect(try after.split().counts["forged"] == [8, 6, 2], "nothing is excluded unless asked")
    }

    @Test("adoption: the anchor under 0.5, the pooled AUC within 0.005 of the parent's, the photoreal AUC at least the parent's")
    func adoption() {
        func evaluation(_ all: Double, _ photoreal: Double, anchor: Double?) -> NoiseprintEvaluation {
            NoiseprintEvaluation(levels: [.init(level: .native, auc: ["ALL": all, "photoreal": photoreal], cameraMean: 0.8, familyMean: [:])],
                                 cameraImages: 10, familyImages: [:], anchor: anchor)
        }
        let parent = evaluation(0.940, 0.80, anchor: 0.43)
        #expect(NoiseprintAdoption.judge(candidate: evaluation(0.936, 0.80, anchor: 0.2), parent: parent).passed, "within 0.005, and equal on photoreal")
        let anchorReadsCamera = NoiseprintAdoption.judge(candidate: evaluation(0.96, 0.9, anchor: 0.578), parent: parent)
        #expect(!anchorReadsCamera.passed && anchorReadsCamera.rules.map(\.passed) == [false, true, true], "the 2026-10-19 retrain's failure")
        #expect(NoiseprintAdoption.judge(candidate: evaluation(0.934, 0.9, anchor: 0.2), parent: parent).rules.map(\.passed) == [true, false, true])
        #expect(NoiseprintAdoption.judge(candidate: evaluation(0.95, 0.79, anchor: 0.2), parent: parent).rules.map(\.passed) == [true, true, false])
        #expect(!NoiseprintAdoption.judge(candidate: evaluation(0.95, 0.9, anchor: nil), parent: parent).passed, "no anchor score, no adoption")
    }

    @Test("the sampler draws seeded patches from the gray plane and drops blank ones")
    func sampler() throws {
        var settings = PatchSettings()
        settings.scaleAugment = false
        settings.levels = [.native]
        let cg = NoiseprintFixture.noise(width: 300, height: 200, seed: 3)
        var a = PythonRandom(seed: 5), b = PythonRandom(seed: 5)
        let (first, level) = try PatchSampler.patches(cg, count: 4, settings: settings, rng: &a)
        let (second, _) = try PatchSampler.patches(cg, count: 4, settings: settings, rng: &b)
        #expect(level == .native)
        #expect(first.count == 4 && first == second)
        #expect(first.allSatisfy { $0.count == 128 * 128 })
        let (gray, w, _) = try #require(NoiseprintLens.grayBytes(cg))
        // Every patch is a window of the gray plane.
        let patch = first[0]
        var found = false
        for y in 0...(200 - 128) where !found {
            for x in 0...(w - 128) where gray[y * w + x] == patch[0] && gray[y * w + x + 1] == patch[1] {
                if (0..<128).allSatisfy({ r in Array(gray[((y + r) * w + x)..<((y + r) * w + x + 128)]) == Array(patch[(r * 128)..<(r * 128 + 128)]) }) { found = true; break }
            }
        }
        #expect(found)
        let flat = NoiseprintFixture.image(width: 200, height: 200) { _, _ in 90 }
        var c = PythonRandom(seed: 5)
        #expect(try PatchSampler.patches(flat, count: 4, settings: settings, rng: &c).patches.isEmpty, "blank patches are dropped, not redrawn")
        let small = NoiseprintFixture.noise(width: 100, height: 100, seed: 4)
        var d = PythonRandom(seed: 5)
        #expect(try PatchSampler.patches(small, count: 4, settings: settings, rng: &d).patches.isEmpty)
    }

    @Test("the recompression levels encode on this Mac and keep the size")
    func levels() throws {
        #expect(ImageCodec.canEncode(.jpeg) && ImageCodec.canEncode(.heic))
        let cg = NoiseprintFixture.noise(width: 160, height: 144, seed: 9)
        for level in NoiseprintLevel.allCases {
            let out = try level.apply(cg)
            #expect(out.width == 160 && out.height == 144, "\(level)")
        }
        #expect(NoiseprintLevel.heic75.recipeName == "webp75")
    }

    @Test("a recipe file's [noiseprint] table")
    func recipeFile() throws {
        let recipe = try RecipeFile.parse("id = \"np\"\n[noiseprint]\nepochs = 2\nper_family = 40\nseed = 7\ncache_patches = false\n")
        guard case .noiseprint(let n)? = recipe.models.first else { Issue.record("no noiseprint model"); return }
        #expect(n.settings.epochs == 2 && n.settings.sources.perFamily == 40 && n.settings.seed == 7 && !n.settings.cachePatches)
        #expect(throws: VeilGardeFailure.self) { try RecipeFile.parse("id = \"np\"\n[noiseprint]\nlr = 1\n") }
        #expect(TrainingRecipe(id: "x") { NoiseprintModel(); Combiner() }.ordered.map(\.name) == ["combiner", "noiseprint"])
    }

    @Test("the plan reads the folders and names the stages without training")
    func plan() throws {
        let s = try SyntheticArea.make()
        defer { s.remove() }
        let root = try NoiseprintFixture.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        var sources = NoiseprintSources(camera: try NoiseprintFixture.folder(root, "camera", count: 12),
                                        negatives: [NoiseprintFamily("a", try NoiseprintFixture.folder(root, "a", count: 10))])
        sources.cameraTrain = 8
        sources.perFamily = 8
        let engine = TrainingEngine(area: s.area, parent: s.parent, store: s.store)
        let plan = try engine.plan(TrainingRecipe(id: "np") { NoiseprintModel().sources(sources).epochs(2) })
        #expect(plan.refusals.isEmpty, "\(plan.refusals)")
        let model = try #require(plan.models.first)
        #expect(model.model == "noiseprint")
        #expect(model.stages.map(\.stage) == [.data, .patches, .fit, .evaluate, .write])
        #expect(model.stages[1].runs, "nothing is cached yet")
        #expect(plan.summary.contains("2 epochs"))
        sources.cameraTrain = 20
        #expect(try engine.plan(TrainingRecipe(id: "np") { NoiseprintModel().sources(sources) }).refusals.count == 1)
    }
}

extension TrainingMLXSuites {
    @Suite("Noiseprint on the GPU", .serialized)
    struct NoiseprintOnGPU {
        static func patches(_ n: Int, seed: UInt64) -> MLXArray {
            var rng = SplitMix64(seed: seed)
            return MLXArray((0..<(n * 128 * 128)).map { _ in Float(rng.next() >> 40) / Float(1 << 24) }, [n, 128, 128, 1])
        }

        @Test("the folded file computes what the trained form computes")
        func fold() throws {
            MLXRandom.seed(11)
            let net = NoiseprintTrainNet()
            net.projectBayar()
            var stats: [String: MLXArray] = [:]
            for (i, c) in NoiseprintTrainNet.channels.dropFirst().enumerated() {
                stats["bn\(i).running_mean"] = MLXRandom.normal([c]) * 0.1
                stats["bn\(i).running_var"] = MLXRandom.uniform(low: 0.5, high: 2.0, [c])
                stats["bn\(i).weight"] = MLXRandom.uniform(low: 0.5, high: 1.5, [c])
                stats["bn\(i).bias"] = MLXRandom.normal([c]) * 0.1
            }
            net.update(parameters: ModuleParameters.unflattened(stats))
            net.train(false)
            let x = Self.patches(6, seed: 2)
            let trained = sigmoid(net(x)).mean().item(Float.self)
            let weights = try net.folded()
            let folded = try NoiseprintNet(weights: weights.mapValues { MLXArray($0.values, $0.shape) })
            #expect(abs(folded.score(x) - trained) <= 1e-5, "folded \(folded.score(x)) against trained \(trained)")
            #expect(weights.keys.sorted() == ["conv0.bias", "conv0.weight", "conv1.bias", "conv1.weight", "conv2.bias", "conv2.weight",
                                              "conv3.bias", "conv3.weight", "linear.bias", "linear.weight"])
            #expect(weights["conv1.weight"]?.shape == [24, 3, 3, 8] && weights["linear.weight"]?.shape == [1, 48])
        }

        @Test("the Bayar projection: centre −1, the other taps of each filter summing to 1")
        func bayar() {
            MLXRandom.seed(3)
            let net = NoiseprintTrainNet()
            net.projectBayar()
            let w = net.conv0.weight.asArray(Float.self)       // [8, 5, 5, 1]
            for f in 0..<8 {
                let taps = Array(w[(f * 25)..<(f * 25 + 25)])
                #expect(taps[12] == -1)
                #expect(abs(taps.enumerated().filter { $0.offset != 12 }.map(\.element).reduce(0, +) - 1) < 1e-5)
            }
        }

        @Test("the shipped net loads into the trained form and folds back to its own bytes",
              .enabled(if: Backbone.shipped(.noiseprint) != nil))
        func shipped() throws {
            let url = try #require(Backbone.shipped(.noiseprint))
            let arrays = try loadArrays(url: url)
            let net = try NoiseprintTrainNet.unfolded(arrays)
            let x = Self.patches(5, seed: 8)
            let original = try NoiseprintNet(weights: arrays).score(x)
            #expect(abs(sigmoid(net(x)).mean().item(Float.self) - original) <= 1e-5)
            #expect(try NoiseprintTrainNet.file(try net.folded()) == Data(contentsOf: url), "the round trip changes the file's bytes")
        }

        @Test("a few epochs on toy patches lower the loss and fold into a working net")
        func trains() throws {
            // Camera = fine noise, everything else = smooth ramps with a little noise.
            var pixels: [UInt8] = [], labels: [UInt8] = []
            var rng = SplitMix64(seed: 21)
            for i in 0..<96 {
                let camera = i % 2 == 0
                for y in 0..<128 { for x in 0..<128 {
                    let jitter = Int(rng.next() >> 61)
                    pixels.append(camera ? UInt8(truncatingIfNeeded: rng.next() >> 56) : UInt8(min(255, (x + y) + jitter)))
                } }
                labels.append(camera ? 1 : 0)
            }
            var settings = NoiseprintSettings()
            settings.epochs = 4
            settings.batch = 32
            let (net, losses) = NoiseprintTrainer.train(PatchSet(patch: 128, pixels: pixels, labels: labels), settings: settings)
            #expect(losses.count == 4)
            #expect(losses.last! < losses.first!, "\(losses)")
            let folded = try NoiseprintNet(weights: try net.folded().mapValues { MLXArray($0.values, $0.shape) })
            var noiseValues = [Float](repeating: 0, count: 128 * 128)
            for i in 0..<noiseValues.count { noiseValues[i] = Float(rng.next() >> 56) / 255 }
            let noise = MLXArray(noiseValues, [1, 128, 128, 1])
            let rampValues: [Float] = (0..<(128 * 128)).map { (i: Int) -> Float in Float(i % 128 + i / 128) / 255 }
            let ramp = MLXArray(rampValues, [1, 128, 128, 1])
            #expect(folded.score(noise) > folded.score(ramp))
        }
    }
}
