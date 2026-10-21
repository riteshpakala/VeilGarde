//
//  CondensedTrainer.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The condensed model as a second route, trained and judged. Each pre-registered arm (the
//        full model and the full model with one input family left out, on the golden core; the full
//        model on the trio and on all 19) trains on final_mixed's joined training images with early
//        stopping on validation, three seeds, and is scored on the test images beside a gradient-
//        boosted model on the same inputs summarized, the trio warp model's sensor call, and the
//        battery's images offline. The admission rules fixed before the run judge every arm.
//  PIN:  AdamW (1e-3, weight decay 1e-4), batch 128, at most 40 epochs, patience 8 on validation AUC,
//        the best epoch's weights kept; each epoch's order a CPython Random(seed + epoch) shuffle and
//        MLXRandom seeded per run. The operating threshold is the sensor calibration's rule, the best
//        recall at a real false-positive rate of at most 0.10 on validation. One MLX workload.
//        Nothing is wired into the detector: the weights and the report are written for measurement.
//

import Foundation
import MLX
import MLXNN
import MLXOptimizers
import VeilGardeCore
import VeilGardeLens

public enum CondensedInput: String, Codable, Sendable { case tiles, aggregates, provenance, semantic }

public struct CondensedArm: Codable, Sendable, Equatable {
    public var name: String
    /// golden | trio | all19
    public var core: String
    public var columns: [Int]
    public var inputs: [CondensedInput]
}

public struct CondensedSettings: Codable, Sendable, Equatable {
    public var epochs = 40
    public var patience = 8
    public var batch = 128
    public var learningRate = 1e-3
    public var weightDecay = 1e-4
    public var tileLossWeight = 0.3
    public var seeds: [UInt64] = [0, 1, 2]
    public var maxRealFPR = 0.10
    /// C1 and C2.
    public var aucTolerance = 0.005
    public var fprTolerance = 0.01
    /// The core study's golden set (nil: all 19).
    public var golden: [Int]? = nil
    /// The arms to run (nil: all).
    public var arms: [String]? = nil
    public var stageParams = BoostParams(trees: 300, maxDepth: 5, eta: 0.04, subsample: 0.8, colsampleByTree: 0.8, seed: 0)
    public var warpParams: BoostParams? = nil
    public var calibration = CalibrationSettings()
    public var cameraPool = "iphone"

    public init() {}

    public var rules: [String] {
        [
            String(format: "C0. Each arm trains on final_mixed's joined training images with early stopping on the validation images (AdamW %g, weight decay %g, batch %d, at most %d epochs, patience %d) and is scored on the test images; seed %@ is the candidate and the others show the spread. Its operating threshold is the sensor calibration's rule: the best generated recall at a real false-positive rate of at most %.2f on validation.",
                   learningRate, weightDecay, batch, epochs, patience, seeds.first.map(String.init) ?? "0", maxRealFPR),
            String(format: "C1. Its test AUC is at least the gradient-boosted model's on the same inputs, the tiles summarized as each core feature's mean, spread, 10th and 90th percentile (the scratch fusion shape), minus %.3f.", aucTolerance),
            String(format: "C2. At the gradient-boosted model's test recall, its real false-positive rate is at most that model's plus %.2f: the research's warning that a blended model can multiply real false positives, measured.", fprTolerance),
            "C3. Offline, it calls every HARD battery image right at its threshold.",
            "C4. Its \(cameraPool) real share on the test images is at least the trio warp model's sensor real share on the same images.",
            "An arm is admissible when C1 to C4 all hold. Nothing is wired into the detector in this run.",
            "The images are final_mixed, the shipped warp model's and the fusion head's own corpus; their DINOv2 and capture rows are the research's extraction.",
        ]
    }
}

public struct CondensedOperating: Codable, Sendable, Equatable {
    public var threshold: Double
    public var auc: Double
    public var recall: Double
    public var realFPR: Double
    public var cameraRealShare: Double?
}

public struct CondensedSeedRun: Codable, Sendable, Equatable {
    public var seed: UInt64
    public var epochs: Int
    public var bestEpoch: Int
    public var validationAUC: Double
    public var testAUC: Double
    public var seconds: Double
}

public struct CondensedRule: Codable, Sendable, Equatable {
    public var rule: String
    public var value: Double?
    public var bar: Double?
    public var passed: Bool
}

public struct CondensedBattery: Codable, Sendable, Equatable {
    public var hardImages: Int
    public var hardRight: Int
    public var wrong: [String]
    public var allImages: Int
    public var allRight: Int
}

public struct CondensedArmResult: Codable, Sendable, Equatable {
    public var arm: CondensedArm
    public var features: [String]
    public var shape: CondensedShape
    public var parameters: Int
    public var seeds: [CondensedSeedRun]
    public var testAUCMean: Double
    public var testAUCSpread: Double
    public var model: CondensedOperating
    public var gbdt: CondensedOperating
    /// The condensed model's real false-positive rate at the gradient-boosted model's test recall.
    public var fprAtGBDTRecall: Double
    public var battery: CondensedBattery
    public var gbdtBattery: CondensedBattery
    public var rules: [CondensedRule]
    public var admissible: Bool
    public var weights: String?
}

public struct CondensedReport: Codable, Sendable {
    public var date: Date
    public var settings: CondensedSettings
    public var rules: [String]
    public var counts: [String: Int]
    /// The trio warp model on the same test images: its vote AUC and its camera pool's sensor real share.
    public var trioVoteAUC: Double
    public var trioCameraRealShare: Double?
    /// The shipped fusion head on the same test images (reliance: these rows trained it).
    public var shippedFusionAUC: Double
    public var arms: [CondensedArmResult]
    public var seconds: Double
}

public enum CondensedTrainer {
    public struct Inputs: Sendable {
        public var tiles: URL
        public var store: URL
        public var aux: URL
        /// The battery's tile cache, judged offline (C3).
        public var batteryTiles: URL
        public var bundle: ModelBundle
        /// Where the weights go (nil: nowhere).
        public var output: URL?

        public init(tiles: URL, store: URL, aux: URL, batteryTiles: URL, bundle: ModelBundle, output: URL?) {
            self.tiles = tiles
            self.store = store
            self.aux = aux
            self.batteryTiles = batteryTiles
            self.bundle = bundle
            self.output = output
        }
    }

    /// Every pre-registered arm, in order.
    public static func registeredArms(_ s: CondensedSettings) -> [CondensedArm] {
        let golden = (s.golden ?? Array(0..<WarpFeatures.count)).sorted(), trio = CoreStudy.trio, all = Array(0..<WarpFeatures.count)
        var arms: [CondensedArm] = [
            CondensedArm(name: "full@golden", core: "golden", columns: golden, inputs: [.tiles, .provenance, .semantic]),
            CondensedArm(name: "no-semantic@golden", core: "golden", columns: golden, inputs: [.tiles, .provenance]),
            CondensedArm(name: "no-provenance@golden", core: "golden", columns: golden, inputs: [.tiles, .semantic]),
            CondensedArm(name: "residual-only@golden", core: "golden", columns: golden, inputs: [.tiles]),
            CondensedArm(name: "semantic+provenance", core: "golden", columns: golden, inputs: [.provenance, .semantic]),
            CondensedArm(name: "aggregates@golden", core: "golden", columns: golden, inputs: [.aggregates, .provenance, .semantic]),
        ]
        if trio != golden { arms.append(CondensedArm(name: "full@trio", core: "trio", columns: trio, inputs: [.tiles, .provenance, .semantic])) }
        if all != golden { arms.append(CondensedArm(name: "full@all19", core: "all19", columns: all, inputs: [.tiles, .provenance, .semantic])) }
        guard let wanted = s.arms else { return arms }
        return arms.filter { wanted.contains($0.name) }
    }

    static func shape(_ arm: CondensedArm) -> CondensedShape {
        CondensedShape(tileChannels: arm.inputs.contains(.tiles) ? arm.columns.count + 3 : 0, aggregateWidth: arm.inputs.contains(.aggregates) ? 4 * arm.columns.count : 0,
                       provenance: arm.inputs.contains(.provenance), semantic: arm.inputs.contains(.semantic))
    }

    /// One batch as the network reads it; branches the shape leaves out get placeholders.
    static func arrays(_ set: CondensedSet, _ idx: [Int], _ shape: CondensedShape) -> [MLXArray] {
        let b = idx.count
        var out: [MLXArray] = []
        if shape.tileChannels > 0 {
            let t = set.maxTiles, c = set.tileChannels
            var tiles = [Float](), mask = [Float](), weights = [Float]()
            tiles.reserveCapacity(b * t * c); mask.reserveCapacity(b * t); weights.reserveCapacity(b * t)
            for i in idx {
                tiles += set.tiles[(i * t * c)..<((i + 1) * t * c)]
                mask += set.mask[(i * t)..<((i + 1) * t)]
                weights += set.weights[(i * t)..<((i + 1) * t)]
            }
            out += [MLXArray(tiles, [b, t, c]), MLXArray(mask, [b, t, 1]), MLXArray(weights, [b, t, 1])]
        } else {
            out += [MLXArray.zeros([b, 1, 1]), MLXArray.zeros([b, 1, 1]), MLXArray.zeros([b, 1, 1])]
        }
        func rows(_ values: [Float], _ width: Int) -> MLXArray {
            var x = [Float]()
            x.reserveCapacity(b * width)
            for i in idx { x += values[(i * width)..<((i + 1) * width)] }
            return MLXArray(x, [b, width])
        }
        out.append(shape.aggregateWidth > 0 ? rows(set.aggregates, set.aggregateWidth) : MLXArray.zeros([b, 1]))
        out.append(rows(set.provenance, CondensedSet.provenanceWidth))
        out.append(shape.semantic ? rows(set.semantic, CondensedSet.semanticWidth) : MLXArray.zeros([b, 1]))
        out.append(MLXArray(idx.map { set.labels[$0] }, [b]))
        return out
    }

    static func predict(_ net: CondensedTrainNet, _ set: CondensedSet) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(set.count)
        for start in stride(from: 0, to: set.count, by: 256) {
            let (logit, _) = net.forward(arrays(set, Array(start..<min(set.count, start + 256)), net.shape))
            out += sigmoid(logit).asArray(Float.self)
        }
        return out
    }

    /// One arm and seed: trained with early stopping, the best epoch's weights restored.
    static func train(_ shape: CondensedShape, train: CondensedSet, validation: CondensedSet, seed: UInt64, _ s: CondensedSettings,
                      note: (String) -> Void) -> (net: CondensedTrainNet, epochs: Int, best: Int, validationAUC: Double) {
        MLXRandom.seed(seed)
        let net = CondensedTrainNet(shape)
        eval(net)
        net.train(true)
        let optimizer = AdamW(learningRate: Float(s.learningRate), weightDecay: Float(s.weightDecay))
        let tileWeight = Float(s.tileLossWeight)
        let step = valueAndGrad(model: net) { model, arrays in [model.loss(arrays, tileWeight: tileWeight)] }
        var best: (auc: Double, epoch: Int, weights: [String: MLXArray])? = nil
        var epochs = 0
        for epoch in 0..<s.epochs {
            epochs = epoch + 1
            var order = Array(0..<train.count)
            var rng = PythonRandom(seed: seed &+ UInt64(epoch))
            rng.shuffle(&order)
            var start = 0
            while start < order.count {
                let idx = Array(order[start..<min(order.count, start + s.batch)])
                let (_, grads) = step(net, arrays(train, idx, shape))
                optimizer.update(model: net, gradients: grads)
                eval(net, optimizer)
                start += idx.count
            }
            net.train(false)
            let auc = Metrics.auc(predict(net, validation), validation.labels)
            net.train(true)
            if best == nil || auc > best!.auc {
                best = (auc, epoch, Dictionary(uniqueKeysWithValues: net.parameters().flattened()))
            } else if epoch - best!.epoch >= s.patience {
                break
            }
        }
        if let best { _ = net.update(parameters: ModuleParameters.unflattened(best.weights)) }
        net.train(false)
        eval(net)
        return (net, epochs, best?.epoch ?? 0, best?.auc ?? .nan)
    }

    /// The sensor calibration's threshold rule on validation, then the rates on test.
    static func operating(validation: [Float], validationLabels: [Float], test: [Float], testLabels: [Float], camera: [Int], maxRealFPR: Double) throws -> CondensedOperating {
        let choice = try OperatingThreshold.choose(labels: validationLabels.map { Int($0) }, probabilities: validation.map(Double.init), maxRealFPR: maxRealFPR)
        let t = choice.threshold
        let gens = test.indices.filter { testLabels[$0] > 0.5 }, reals = test.indices.filter { testLabels[$0] < 0.5 }
        return CondensedOperating(threshold: t, auc: Metrics.auc(test, testLabels),
                                  recall: Double(gens.filter { Double(test[$0]) > t }.count) / Double(max(1, gens.count)),
                                  realFPR: Double(reals.filter { Double(test[$0]) > t }.count) / Double(max(1, reals.count)),
                                  cameraRealShare: camera.isEmpty ? nil : Double(camera.filter { Double(test[$0]) <= t }.count) / Double(camera.count))
    }

    /// The real false-positive rate at the first threshold that reaches `recall` on these scores.
    static func fpr(_ p: [Float], _ labels: [Float], atRecall recall: Double) -> Double {
        let gens = p.indices.filter { labels[$0] > 0.5 }.map { p[$0] }.sorted(by: >), reals = p.indices.filter { labels[$0] < 0.5 }.map { p[$0] }
        let k = Int((recall * Double(gens.count)).rounded(.up))
        guard k > 0, !reals.isEmpty else { return 0 }
        let cut = gens[min(gens.count, k) - 1]
        return Double(reals.filter { $0 >= cut }.count) / Double(reals.count)
    }

    static func battery(_ p: [Float], _ join: ResearchJoin, rows: [Int], threshold: Double) -> CondensedBattery {
        var b = CondensedBattery(hardImages: 0, hardRight: 0, wrong: [], allImages: rows.count, allRight: 0)
        for (k, i) in rows.enumerated() {
            let image = join.images[i], right = image.label == 1 ? Double(p[k]) > threshold : Double(p[k]) <= threshold
            if right { b.allRight += 1 }
            guard image.tag?.hasPrefix("HARD") == true else { continue }
            b.hardImages += 1
            if right { b.hardRight += 1 } else { b.wrong.append("\(image.pool ?? "?")/\((image.path as NSString).lastPathComponent)") }
        }
        return b
    }

    public static func run(_ inputs: Inputs, settings s: CondensedSettings, note: (String) -> Void = { _ in }) throws -> CondensedReport {
        let started = Date()
        let join = try ResearchJoin.finalMixed(tiles: inputs.tiles, store: inputs.store, aux: inputs.aux)
        let batteryJoin = try ResearchJoin.battery(tiles: inputs.batteryTiles, aux: inputs.aux)
        let trainRows = join.indices(in: [.train]), validationRows = join.indices(in: [.val]), testRows = join.indices(in: [.test])
        let batteryRows = Array(batteryJoin.images.indices)
        let testLabels = testRows.map { Float(join.images[$0].label) }, validationLabels = validationRows.map { Float(join.images[$0].label) }
        let camera = testRows.indices.filter { join.images[testRows[$0]].pool == s.cameraPool }
        var counts = join.counts
        counts["train"] = trainRows.count; counts["validation"] = validationRows.count; counts["test"] = testRows.count
        counts["test \(s.cameraPool)"] = camera.count; counts["battery"] = batteryJoin.images.count
        counts["battery HARD"] = batteryJoin.images.filter { $0.tag?.hasPrefix("HARD") == true }.count
        note("condensed: \(trainRows.count) train, \(validationRows.count) validation, \(testRows.count) test images; \(batteryJoin.images.count) battery images")

        // The comparators: the trio warp model's sensor call and the shipped fusion head (reliance).
        let data = CoreStudy.sets(try TileCache(directory: inputs.tiles).load(), leftOut: nil)
        let trio = CoreStudy.model(CoreStudy.trio, seed: 0, train: data.train, params: s.warpParams ?? WarpShape.deployed.params)
        let trioCuts = try CoreStudy.cuts(validation: data.validation, majority: WarpTrainer.imageScores(trio, data.validation).majority,
                                          sha256: ContentHash.sha256Hex(trio.encodeXGBoostJSON()), featureCount: trio.featureCount, settings: s.calibration).cuts
        let trioViews = ResidualView.all(trio, join.tiles, columns: [])
        let trioVotes = testRows.map { trioViews[$0].vote }
        let trioCamera = camera.isEmpty ? nil : Double(camera.filter { trioCuts.call(trioVotes[$0]) == "real" }.count) / Double(camera.count)
        guard let warpURL = inputs.bundle.url(.warpTile), let fusionURL = inputs.bundle.url(.fusionHead) else { throw VeilGardeFailure.missing("the bundle has no warp model or fusion head") }
        let shippedViews = ResidualView.all(try GBDTModel.load(warpURL), join.tiles, columns: [])
        let fusion = try GBDTModel.load(fusionURL)
        let shippedFusion = testRows.map { fusion.predict([shippedViews[$0].weighted] + join.images[$0].dinoFusion + join.images[$0].cap + shippedViews[$0].sharp) }
        note(String(format: "condensed: the trio warp model's vote AUC %.4f, %@ sensor real %.3f; the shipped fusion head's AUC %.4f (reliance)",
                    Metrics.auc(trioVotes, testLabels), s.cameraPool, trioCamera ?? .nan, Metrics.auc(shippedFusion, testLabels)))

        var sets: [[Int]: (normalizer: CondensedNormalizer, train: CondensedSet, validation: CondensedSet, test: CondensedSet, battery: CondensedSet)] = [:]
        var results: [CondensedArmResult] = []
        for arm in registeredArms(s) {
            if sets[arm.columns] == nil {
                let z = CondensedSet.normalizer(join, train: trainRows, columns: arm.columns)
                sets[arm.columns] = (z, CondensedSet(join, rows: trainRows, columns: arm.columns, normalizer: z),
                                     CondensedSet(join, rows: validationRows, columns: arm.columns, normalizer: z),
                                     CondensedSet(join, rows: testRows, columns: arm.columns, normalizer: z),
                                     CondensedSet(batteryJoin, rows: batteryRows, columns: arm.columns, normalizer: z))
            }
            let set = sets[arm.columns]!
            let shape = Self.shape(arm)
            var seeds: [CondensedSeedRun] = []
            var candidate: (net: CondensedTrainNet, validation: [Float], test: [Float], battery: [Float])? = nil
            for seed in s.seeds {
                let t0 = Date()
                let fit = train(shape, train: set.train, validation: set.validation, seed: seed, s, note: note)
                let test = predict(fit.net, set.test)
                seeds.append(CondensedSeedRun(seed: seed, epochs: fit.epochs, bestEpoch: fit.best, validationAUC: fit.validationAUC,
                                              testAUC: Metrics.auc(test, testLabels), seconds: Date().timeIntervalSince(t0)))
                if candidate == nil { candidate = (fit.net, predict(fit.net, set.validation), test, predict(fit.net, set.battery)) }
                note(String(format: "condensed: %@ seed %llu: %d epochs (best %d), validation AUC %.4f, test AUC %.4f, %.0fs", arm.name, seed, fit.epochs,
                            fit.best + 1, fit.validationAUC, seeds.last!.testAUC, seeds.last!.seconds))
                LensRuntime.releaseMemory()
            }
            let c = candidate!
            let model = try operating(validation: c.validation, validationLabels: validationLabels, test: c.test, testLabels: testLabels, camera: camera, maxRealFPR: s.maxRealFPR)

            // The gradient-boosted model on the same inputs, summarized.
            let flat = (train: CondensedSet.flat(join, rows: trainRows, columns: arm.columns), validation: CondensedSet.flat(join, rows: validationRows, columns: arm.columns),
                        test: CondensedSet.flat(join, rows: testRows, columns: arm.columns), battery: CondensedSet.flat(batteryJoin, rows: batteryRows, columns: arm.columns))
            func vector(_ f: (aggregates: [[Float]], provenance: [[Float]], semantic: [[Float]]), _ k: Int) -> [Float] {
                (arm.inputs.contains(.tiles) || arm.inputs.contains(.aggregates) ? f.aggregates[k] : [])
                    + (arm.inputs.contains(.provenance) ? f.provenance[k] : []) + (arm.inputs.contains(.semantic) ? f.semantic[k] : [])
            }
            let width = vector(flat.train, 0).count
            let gbdtModel = BoostTrainer.train(BoostDataset(x: trainRows.indices.flatMap { vector(flat.train, $0) }, y: trainRows.map { Float(join.images[$0].label) }, features: width),
                                               params: s.stageParams).model
            let gv = validationRows.indices.map { gbdtModel.predict(vector(flat.validation, $0)) }, gt = testRows.indices.map { gbdtModel.predict(vector(flat.test, $0)) }
            let gb = batteryRows.indices.map { gbdtModel.predict(vector(flat.battery, $0)) }
            let gbdt = try operating(validation: gv, validationLabels: validationLabels, test: gt, testLabels: testLabels, camera: camera, maxRealFPR: s.maxRealFPR)
            let fprAt = fpr(c.test, testLabels, atRecall: gbdt.recall)
            let bat = battery(c.battery, batteryJoin, rows: batteryRows, threshold: model.threshold)
            let gbdtBat = battery(gb, batteryJoin, rows: batteryRows, threshold: gbdt.threshold)
            var rules = [
                CondensedRule(rule: "C1: test AUC at least the gradient-boosted model's minus \(s.aucTolerance)", value: model.auc, bar: gbdt.auc - s.aucTolerance,
                              passed: model.auc >= gbdt.auc - s.aucTolerance),
                CondensedRule(rule: "C2: real FPR at the gradient-boosted model's recall at most its own plus \(s.fprTolerance)", value: fprAt, bar: gbdt.realFPR + s.fprTolerance,
                              passed: fprAt <= gbdt.realFPR + s.fprTolerance),
                CondensedRule(rule: "C3: every HARD battery image called right", value: Double(bat.hardRight), bar: Double(bat.hardImages), passed: bat.hardRight == bat.hardImages),
            ]
            if let mine = model.cameraRealShare, let trioShare = trioCamera {
                rules.append(CondensedRule(rule: "C4: \(s.cameraPool) real share at least the trio warp model's sensor real share", value: mine, bar: trioShare, passed: mine >= trioShare))
            } else {
                rules.append(CondensedRule(rule: "C4: \(s.cameraPool) real share at least the trio warp model's", value: nil, bar: nil, passed: false))
            }
            let aucs = seeds.map(\.testAUC), mean = aucs.reduce(0, +) / Double(max(1, aucs.count))
            let spread = (aucs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(1, aucs.count))).squareRoot()
            let active = c.net.activeParameters()
            var weightsPath: String? = nil
            if let output = inputs.output {
                let dir = output.appendingPathComponent(arm.name.replacingOccurrences(of: "@", with: "-").replacingOccurrences(of: "+", with: "-"), isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("condensed_v0.safetensors")
                try save(arrays: active, metadata: ["format": "veilgarde-condensed-v0", "arm": arm.name], url: file)
                try JSONCoding.write(CondensedFile(arm: arm, features: arm.columns.map { WarpFeatures.names[$0] }, shape: shape, normalizer: set.normalizer,
                                                   threshold: model.threshold, maxTiles: set.train.maxTiles), to: dir.appendingPathComponent("condensed_v0.json"))
                weightsPath = file.path
            }
            let result = CondensedArmResult(arm: arm, features: arm.columns.map { WarpFeatures.names[$0] }, shape: shape, parameters: active.values.reduce(0) { $0 + $1.size },
                                            seeds: seeds, testAUCMean: mean, testAUCSpread: spread, model: model, gbdt: gbdt, fprAtGBDTRecall: fprAt, battery: bat,
                                            gbdtBattery: gbdtBat, rules: rules, admissible: rules.allSatisfy(\.passed), weights: weightsPath)
            results.append(result)
            note(String(format: "condensed: %@ — test AUC %.4f (the boosted model's %.4f), real FPR at its recall %.3f against %.3f, HARD battery %d of %d, %@ real %.3f — %@",
                        arm.name, model.auc, gbdt.auc, fprAt, gbdt.realFPR, bat.hardRight, bat.hardImages, s.cameraPool, model.cameraRealShare ?? .nan,
                        result.admissible ? "admissible" : "not admissible: " + rules.filter { !$0.passed }.map { String($0.rule.prefix(2)) }.joined(separator: ", ")))
        }
        return CondensedReport(date: Date(), settings: s, rules: s.rules, counts: counts, trioVoteAUC: Metrics.auc(trioVotes, testLabels), trioCameraRealShare: trioCamera,
                               shippedFusionAUC: Metrics.auc(shippedFusion, testLabels), arms: results, seconds: Date().timeIntervalSince(started))
    }
}

/// What a condensed model's weights need beside them to be read again.
public struct CondensedFile: Codable, Sendable, Equatable {
    public var arm: CondensedArm
    public var features: [String]
    public var shape: CondensedShape
    public var normalizer: CondensedNormalizer
    public var threshold: Double
    public var maxTiles: Int
}
