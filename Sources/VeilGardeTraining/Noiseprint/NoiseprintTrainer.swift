//
//  NoiseprintTrainer.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The noiseprint, trained from images: the reference split (NoiseprintData), the patches
//        (PatchSampler, cached in the work area), six epochs of Adam on binary cross-entropy with
//        the Bayar projection after every step, the BatchNorms folded into the file NoiseprintNet
//        loads, then the reference's held-out test: camera originals against each negative family,
//        image by image (the mean sigmoid of the 4×4 patch grid, exactly as inference scores),
//        at three recompression levels, beside the parent's net on the same images, and the
//        adversarial anchor that forged a capture peak of 568 and must not read camera. The anchor
//        is excluded from every folder the split lists, and the report judges the candidate
//        against the adoption rules fixed before the photoreal retrain (NoiseprintAdoption).
//  PIN:  the v202 reference: Adam 2e-3 (PyTorch's, so bias-corrected), batch 256, 6 epochs, BCE with logits,
//        the constraint projected once before training and after every step. Each epoch's
//        order is a CPython Random(seed + epoch) shuffle (the reference used numpy's default_rng(epoch)).
//        The weights start from MLXRandom's seed. The test levels are native, JPEG 0.75 and HEIC
//        0.75 (the reference's native, q75, webp75). The parent's numbers are measured, not trusted: its
//        training split came from the reference's glob order, so some of these held-out images may have
//        trained it, and its numbers read high by however many did. Training is one MLX workload
//        on the calling thread; patch cutting and test preparation are CPU work in parallel.
//

import CoreGraphics
import Foundation
import MLX
import MLXNN
import MLXOptimizers
import VeilGardeCore
import VeilGardeLens

public struct NoiseprintSettings: Codable, Sendable, Equatable {
    public var sources = NoiseprintSources.standard
    public var patches = PatchSettings()
    public var epochs = 6
    public var batch = 256
    public var learningRate = 2e-3
    public var seed: UInt64 = 0
    public var testLevels: [NoiseprintLevel] = [.native, .jpeg75, .heic75]
    /// The photoreal AI image that forged a capture peak of 568 (it must read low).
    public var anchor: String? = WorkArea.datasets()?.appendingPathComponent("ig_fullres/generated/ig_4382a71faeeee1.jpg").path
    public var cachePatches = true

    public init() {}

    /// The split these settings train and test on: the sources' split, the anchor excluded.
    public func split() throws -> NoiseprintSplit { try sources.split(excluding: anchor.map { [$0] } ?? []) }
}

/// The rules a retrained net must meet before it may replace the shipped one, fixed before the
/// photoreal retrain ran (ledger decision-67), all on native images: the anchor under 0.5; the
/// pooled AUC (camera against every family) at least the parent's minus 0.005; the photoreal
/// family's AUC at least the parent's. Passing them stages a candidate; the shipped default
/// changes only on the owner's word.
public struct NoiseprintAdoption: Codable, Sendable, Equatable {
    public struct Rule: Codable, Sendable, Equatable {
        public var rule: String
        public var value: Double?
        public var bar: Double?
        public var passed: Bool
    }

    public var rules: [Rule]
    public var passed: Bool

    public static func judge(candidate: NoiseprintEvaluation, parent: NoiseprintEvaluation?, family: String = "photoreal") -> NoiseprintAdoption {
        let c = candidate.levels.first { $0.level == .native }, p = parent?.levels.first { $0.level == .native }
        func atLeast(_ value: Double?, _ bar: Double?) -> Bool {
            guard let value, let bar, value.isFinite, bar.isFinite else { return false }
            return value >= bar
        }
        let rules = [
            Rule(rule: "the anchor reads P(camera) below 0.5", value: candidate.anchor, bar: 0.5, passed: candidate.anchor.map { $0 < 0.5 } ?? false),
            Rule(rule: "the pooled AUC is at least the parent's minus 0.005", value: c?.auc["ALL"], bar: p?.auc["ALL"].map { $0 - 0.005 },
                 passed: atLeast(c?.auc["ALL"], p?.auc["ALL"].map { $0 - 0.005 })),
            Rule(rule: "the \(family) AUC is at least the parent's", value: c?.auc[family], bar: p?.auc[family], passed: atLeast(c?.auc[family], p?.auc[family])),
        ]
        return NoiseprintAdoption(rules: rules, passed: rules.allSatisfy(\.passed))
    }
}

public struct NoiseprintEvaluation: Codable, Sendable, Equatable {
    public struct Level: Codable, Sendable, Equatable {
        public var level: NoiseprintLevel
        /// Camera against each family, and "ALL" against every family pooled.
        public var auc: [String: Double]
        public var cameraMean: Double
        public var familyMean: [String: Double]
    }

    public var levels: [Level]
    public var cameraImages: Int
    public var familyImages: [String: Int]
    /// P(camera) of the anchor, native.
    public var anchor: Double?
}

public struct NoiseprintReport: Codable, Sendable {
    public var settings: NoiseprintSettings
    /// Per family (and camera): images found, used for training, held out.
    public var counts: [String: [Int]]
    public var missingFamilies: [String]
    /// Files the split left out of every folder (the anchor, and any copy of it).
    public var excluded: [String]
    public var patchesPerClass: Int
    public var cameraPatchesCut: Int
    public var negativePatchesCut: Int
    public var levelsDrawn: [String: Int]
    public var patchCache: String?
    public var patchCacheHit: Bool
    public var failedImages: [String]
    public var epochLoss: [Double]
    public var trainSeconds: Double
    public var candidate: NoiseprintEvaluation
    public var parent: NoiseprintEvaluation?
    public var parentSHA256: String?
    public var parentNote: String
    /// The candidate against the adoption rules; nil without a parent to judge it against.
    public var adoption: NoiseprintAdoption?
    public var sha256: String
    public var departures: [String]
}

public enum NoiseprintTrainer {
    public static let departures = [
        "ai_art reads Midjourney v6 (mj_pool); shot_render and cgi have no surviving images; ai_video and photoreal (Instagram photoreal AI at full resolution) are added",
        "the adversarial anchor is excluded from every folder, by path and by content, before the split",
        "each image draws its patches from its own CPython Random stream (seed, index), not one stream over all images",
        "the levels are ImageIO's: JPEG 0.90/0.75/0.60 for cv2's q90/q75/q60, HEIC 0.75 for WebP 75 (ImageIO has no WebP encoder)",
        "the downscale is CoreGraphics' high-quality draw, not cv2's INTER_AREA",
        "folders are listed sorted, not in glob order; each epoch shuffles with CPython Random(seed + epoch), not numpy",
        "images decode through NSImage / ImageIO and gray is round(BT.601) of device RGB, as inference reads them, not cv2's",
    ]

    // MARK: Patches

    public struct PatchResult {
        public var set: PatchSet
        public var cameraCut: Int
        public var negativeCut: Int
        public var levels: [String: Int]
        public var failed: [String]
        public var cache: URL?
        public var hit: Bool
    }

    /// Where the work area keeps the noiseprint's patch caches.
    public static func cacheDirectory(_ area: WorkArea) -> URL { area.root.appendingPathComponent("noiseprint", isDirectory: true) }

    /// The reference split and its patches, cut into (or read from) the cache: the CPU half of a run, which
    /// `veilgarde features patches` does ahead of the GPU half.
    public static func cut(settings: NoiseprintSettings, cacheDirectory: URL, note: (String) -> Void = { _ in }) throws -> (split: NoiseprintSplit, patches: PatchResult) {
        let split = try settings.split()
        return (split, try patches(split, settings: settings, cacheDirectory: cacheDirectory, note: note))
    }

    /// The patch cache's key: everything that decides the patches.
    static func cacheKey(_ split: NoiseprintSplit, _ settings: NoiseprintSettings) throws -> String {
        struct Key: Encodable {
            var format = "veilgarde-noiseprint-patches-v1"
            var patches: PatchSettings
            var camera: [String]
            var negatives: [String]
        }
        let key = Key(patches: settings.patches, camera: split.cameraTrain.map(\.path), negatives: split.negativeTrain.map(\.path))
        return String(ContentHash.sha256Hex(try JSONCoding.lineEncoder().encode(key)).prefix(16))
    }

    static func patches(_ split: NoiseprintSplit, settings: NoiseprintSettings, cacheDirectory: URL?, note: (String) -> Void) throws -> PatchResult {
        let p = settings.patches.patch
        let key = try cacheKey(split, settings)
        let cache = cacheDirectory?.appendingPathComponent("patches_\(key).safetensors")
        if settings.cachePatches, let cache, FileManager.default.fileExists(atPath: cache.path) {
            let file = try SafetensorsFile(url: cache)
            let set = PatchSet(patch: p, pixels: try file.uint8("patches"), labels: try file.uint8("labels"))
            note("noiseprint: patch cache hit, \(set.count) patches (\(cache.lastPathComponent))")
            let meta = file.metadata
            return PatchResult(set: set, cameraCut: Int(meta["camera_cut"] ?? "") ?? 0, negativeCut: Int(meta["negative_cut"] ?? "") ?? 0,
                               levels: (try? JSONDecoder().decode([String: Int].self, from: Data((meta["levels"] ?? "{}").utf8))) ?? [:],
                               failed: (try? JSONDecoder().decode([String].self, from: Data((meta["failed"] ?? "[]").utf8))) ?? [], cache: cache, hit: true)
        }
        note("noiseprint: cutting patches from \(split.cameraTrain.count) camera and \(split.negativeTrain.count) negative images")
        let cam = PatchSampler.sample(split.cameraTrain, count: settings.patches.cameraPatches, settings: settings.patches, streamOffset: 0, note: note)
        let neg = PatchSampler.sample(split.negativeTrain, count: settings.patches.negativePatches, settings: settings.patches,
                                      streamOffset: split.cameraTrain.count, note: note)
        let n = min(cam.patches.count, neg.patches.count)
        guard n > 0 else { throw VeilGardeFailure.data("no patches were cut (camera \(cam.patches.count), negatives \(neg.patches.count))") }
        var pixels = [UInt8]()
        pixels.reserveCapacity(2 * n * p * p)
        for patch in cam.patches.prefix(n) { pixels += patch }
        for patch in neg.patches.prefix(n) { pixels += patch }
        let labels = [UInt8](repeating: 1, count: n) + [UInt8](repeating: 0, count: n)
        var levels: [String: Int] = [:]
        for (level, count) in cam.levels { levels[level.rawValue, default: 0] += count }
        for (level, count) in neg.levels { levels[level.rawValue, default: 0] += count }
        let failed = cam.failed + neg.failed
        let set = PatchSet(patch: p, pixels: pixels, labels: labels)
        if settings.cachePatches, let cache {
            let meta: [String: String] = [
                "format": "veilgarde-noiseprint-patches-v1", "key": key, "camera_cut": "\(cam.patches.count)", "negative_cut": "\(neg.patches.count)",
                "levels": String(decoding: try JSONCoding.lineEncoder().encode(levels), as: UTF8.self),
                "failed": String(decoding: try JSONCoding.lineEncoder().encode(failed), as: UTF8.self),
            ]
            try SafetensorsWriter.write([.init("patches", shape: [2 * n, p, p], .uint8(pixels)), .init("labels", shape: [2 * n], .uint8(labels))],
                                        metadata: meta, to: cache)
            note("noiseprint: \(2 * n) patches cached at \(cache.path)")
        }
        return PatchResult(set: set, cameraCut: cam.patches.count, negativeCut: neg.patches.count, levels: levels, failed: failed, cache: cache, hit: false)
    }

    // MARK: Training

    /// Six epochs (by default) over `set`; returns the trained net (in eval mode) and each epoch's mean loss.
    public static func train(_ set: PatchSet, settings: NoiseprintSettings, note: (String) -> Void = { _ in }) -> (NoiseprintTrainNet, [Double]) {
        MLXRandom.seed(settings.seed)
        let net = NoiseprintTrainNet()
        net.projectBayar()
        eval(net)
        net.train(true)
        let optimizer = Adam(learningRate: Float(settings.learningRate), biasCorrection: true)
        let step = valueAndGrad(model: net) { model, x, y in
            binaryCrossEntropy(logits: model(x).squeezed(axis: 1), targets: y, reduction: .mean)
        }
        let p = set.patch, n = set.count
        var losses: [Double] = []
        var buffer = [Float](repeating: 0, count: settings.batch * p * p)
        for epoch in 0..<settings.epochs {
            let started = Date()
            var order = Array(0..<n)
            var rng = PythonRandom(seed: settings.seed &+ UInt64(epoch))
            rng.shuffle(&order)
            var total = 0.0
            var start = 0
            while start < n {
                let batch = Array(order[start..<min(start + settings.batch, n)])
                for (j, i) in batch.enumerated() { set.floats(i, into: &buffer, at: j * p * p) }
                let x = MLXArray(Array(buffer.prefix(batch.count * p * p)), [batch.count, p, p, 1])
                let y = MLXArray(batch.map { Float(set.labels[$0]) })
                let (loss, grads) = step(net, x, y)
                optimizer.update(model: net, gradients: grads)
                net.projectBayar()
                eval(net, optimizer)
                total += Double(loss.item(Float.self)) * Double(batch.count)
                start += batch.count
            }
            losses.append(total / Double(n))
            note(String(format: "noiseprint: epoch %d/%d loss %.4f (%.0fs)", epoch + 1, settings.epochs, total / Double(n), Date().timeIntervalSince(started)))
        }
        net.train(false)
        return (net, losses)
    }

    // MARK: The held-out test

    /// The 4×4 grid of each held-out image at each level, prepared on the CPU in parallel.
    static func prepare(_ urls: [URL], levels: [NoiseprintLevel]) -> [[(values: [Float], count: Int)?]] {
        var out = [[(values: [Float], count: Int)?]](repeating: [], count: urls.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            var row: [(values: [Float], count: Int)?] = []
            let cg = (try? ImageDecoding.cgImage(contentsOf: urls[i])).flatMap(ImageCodec.flattened)
            for level in levels {
                guard let cg, let degraded = try? level.apply(cg), let (g, w, h) = NoiseprintLens.grayPlane(degraded) else { row.append(nil); continue }
                row.append(NoiseprintLens.gridPatchValues(g, w, h))
            }
            lock.lock(); out[i] = row; lock.unlock()
        }
        return out
    }

    /// Camera against each family at each level, scored by `net` image by image.
    public static func evaluate(_ net: NoiseprintNet, split: NoiseprintSplit, settings: NoiseprintSettings, note: (String) -> Void = { _ in }) -> NoiseprintEvaluation {
        let p = NoiseprintNet.patch
        func scores(_ urls: [URL]) -> [[Float?]] {
            prepare(urls, levels: settings.testLevels).map { row in
                row.map { grid in grid.map { net.score(MLXArray($0.values, [$0.count, p, p, 1])) } }
            }
        }
        let camera = scores(split.cameraTest)
        let families = split.negativeTest.map { (family: $0.family, scores: scores($0.urls)) }
        var levels: [NoiseprintEvaluation.Level] = []
        for (k, level) in settings.testLevels.enumerated() {
            let cam = camera.compactMap { $0[k] }
            var auc: [String: Double] = [:], familyMean: [String: Double] = [:]
            var pooled: [Float] = []
            for family in families {
                let neg = family.scores.compactMap { $0[k] }
                guard !neg.isEmpty else { continue }
                pooled += neg
                auc[family.family] = Metrics.auc(cam + neg, [Float](repeating: 1, count: cam.count) + [Float](repeating: 0, count: neg.count))
                familyMean[family.family] = Double(neg.reduce(0, +)) / Double(neg.count)
            }
            auc["ALL"] = Metrics.auc(cam + pooled, [Float](repeating: 1, count: cam.count) + [Float](repeating: 0, count: pooled.count))
            levels.append(.init(level: level, auc: auc, cameraMean: cam.isEmpty ? .nan : Double(cam.reduce(0, +)) / Double(cam.count), familyMean: familyMean))
            note("noiseprint: \(level.rawValue): ALL AUC " + String(format: "%.3f", auc["ALL"] ?? .nan) + "; "
                 + families.map { "\($0.family) " + String(format: "%.3f", auc[$0.family] ?? .nan) }.joined(separator: ", "))
        }
        var anchor: Double?
        if let path = settings.anchor, let cg = try? ImageDecoding.cgImage(contentsOf: URL(fileURLWithPath: path)),
           let (g, w, h) = NoiseprintLens.grayPlane(cg), let grid = NoiseprintLens.gridPatches(g, w, h) {
            anchor = Double(net.score(grid))
        }
        return NoiseprintEvaluation(levels: levels, cameraImages: split.cameraTest.count,
                                    familyImages: Dictionary(uniqueKeysWithValues: split.negativeTest.map { ($0.family, $0.urls.count) }), anchor: anchor)
    }

    // MARK: End to end

    /// Split, patches, training, the folded file, and the test beside `parent`'s net.
    public static func run(settings: NoiseprintSettings, cacheDirectory: URL?, parent: URL?, note: (String) -> Void = { _ in }) throws -> (file: Data, report: NoiseprintReport) {
        let split = try settings.split()
        if !split.excluded.isEmpty { note("noiseprint: excluded from every folder: " + split.excluded.joined(separator: ", ")) }
        note("noiseprint: " + split.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value[1])/\($0.value[2]) of \($0.value[0])" }.joined(separator: ", ") + " (train/test of found)")
        let empty = settings.sources.negatives.filter { (split.counts[$0.name]?[0] ?? 0) == 0 }.map(\.name)
        guard empty.count < settings.sources.negatives.count else { throw VeilGardeFailure.missing("no negative family has images") }
        let cut = try patches(split, settings: settings, cacheDirectory: cacheDirectory, note: note)
        let started = Date()
        let (net, losses) = train(cut.set, settings: settings, note: note)
        let trainSeconds = Date().timeIntervalSince(started)
        let weights = try net.folded()
        let file = try NoiseprintTrainNet.file(weights)
        let folded = try NoiseprintNet(weights: weights.mapValues { MLXArray($0.values, $0.shape) })
        note("noiseprint: testing the candidate")
        let candidate = evaluate(folded, split: split, settings: settings, note: note)
        var parentEval: NoiseprintEvaluation?, parentSHA: String?
        if let parent {
            note("noiseprint: testing the parent \(parent.lastPathComponent)")
            parentEval = evaluate(try NoiseprintNet(weights: try loadArrays(url: parent)), split: split, settings: settings, note: note)
            parentSHA = try ContentHash.sha256Hex(fileAt: parent)
        }
        let adoption = parentEval.map { NoiseprintAdoption.judge(candidate: candidate, parent: $0) }
        if let adoption {
            for r in adoption.rules {
                note("noiseprint: adoption: \(r.passed ? "pass" : "FAIL")  \(r.rule): " + (r.value.map { String(format: "%.4f", $0) } ?? "n/a")
                     + (r.bar.map { String(format: " (bar %.4f)", $0) } ?? ""))
            }
            note("noiseprint: adoption " + (adoption.passed ? "PASSED: the net may be staged; the shipped default changes only on the owner's word" : "FAILED: the shipped net stays"))
        }
        let report = NoiseprintReport(settings: settings, counts: split.counts, missingFamilies: NoiseprintSources.unavailableFamilies + empty, excluded: split.excluded,
                                      patchesPerClass: cut.set.count / 2, cameraPatchesCut: cut.cameraCut, negativePatchesCut: cut.negativeCut,
                                      levelsDrawn: cut.levels, patchCache: cut.cache?.path, patchCacheHit: cut.hit, failedImages: cut.failed,
                                      epochLoss: losses, trainSeconds: trainSeconds, candidate: candidate, parent: parentEval, parentSHA256: parentSHA,
                                      parentNote: "the parent's net on the same held-out images; its own split came from a glob order, so some of these images may have trained it",
                                      adoption: adoption,
                                      sha256: ContentHash.sha256Hex(file), departures: departures)
        return (file, report)
    }
}
