//
//  main.swift
//  VeilGardePlayground
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: VeilGarde end to end, top to bottom. The inference regime first, one core part at a time: the
//        warp lens on one image (its tiles and their 19 features), the base warp model alone and
//        the camera-sensor score it yields (did a real camera make this?), the capture signature,
//        the fusion head, then the stacked specialists and the full verdict, the combiner's
//        arithmetic printed term by term. Then the training regime in miniature (step 7: a
//        recipe, its plan, the engine, a candidate bundle), the flywheel loop (step 8: a live
//        bundle, a battery, a promote and its rollback) and the watermark (step 9: a signature
//        from the same residual, matched by a crop and a re-encode). Every step checks itself against
//        Garde's goldens where one exists.
//  IN:   The weights in the work area or VEILGARDE_WEIGHTS; final_mixed under VEILGARDE_DATASETS
//        for the iPhone sample (optional). Run by Playground/run.sh.
//  OUT:  One numbered block per step; Playground/.work for the training steps. Exit 0 only when
//        every checkpoint holds.
//  PIN:  One MLX workload at a time; everything runs on this thread. Checkpoints compare against
//        Garde: the warp lens leaf for leaf, the routed result with labels exact and numbers within
//        1e-4 (Frigate's Metal kernels move DINOv2 by about 1e-5), both but for the sensor fields the
//        two cuts changed on purpose (ResultJSON.changedSinceGarde), whose call is Garde's.
//

import Foundation
import VeilGarde

setvbuf(stdout, nil, _IOLBF, 0)
let checks = Checkpoints()

func run() throws {
    // 0. MLX's Metal library beside this binary, before anything touches MLX.
    if let source = try Scratch.installMetalLibrary() { Show.step(0, "metal", "mlx.metallib copied beside this binary from \(source)") }
    ShippedBundle.registerWeightFolders()
    let bundle = try ShippedBundle.verified()
    Show.step(0, "bundle", "the shipped bundle: \(bundle.manifest.artifacts.count) artifacts verified against manifest.json")

    // 1. The images.
    let crops = Images.parityCrops
    let sample = Images.sample()
    Show.step(1, "images", "\(crops.count) parity crops with Garde's goldens" + (sample.isEmpty ? "; the T9 is not mounted, no iPhone sample" : "; \(sample.count) from final_mixed (\(sample.filter { $0.label == 0 }.count) iPhone originals, \(sample.filter { $0.label == 1 }.count) generated)"))

    // 2. The warp lens on one image: tiles, the residual, the 19 features of one tile.
    let first = crops[0]
    let cg = try ImageDecoding.cgImage(contentsOf: first.url)
    let (tiles, geometry) = try WarpLens.tileFeatures(cgImage: cg)
    Show.step(2, "lens", "\(first.name): \(cg.width)×\(cg.height), scored \(geometry.scoringWidth)×\(geometry.scoringHeight) as \(tiles.tileRows)×\(tiles.tileCols) tiles of 32 px")
    Show.line("each tile warped through 16 fixed homographies at strengths 0.025 and 0.05 and back; the round-trip residual, high-passed, is measured")
    let centre = (tiles.tileRows / 2) * tiles.tileCols + tiles.tileCols / 2
    let row = tiles.row(centre)
    Show.line("the centre tile's 19 features:")
    for (k, name) in WarpFeatures.names.enumerated() { Show.line("  " + name.padding(toLength: 12, withPad: " ", startingAt: 0) + String(format: "%10.5f", row[row.startIndex + k])) }
    let meanFR = (0..<tiles.count).map { tiles.row($0).first! }.reduce(0, +) / Float(tiles.count)
    Show.line("mean fragility rate over the image: \(Show.f(meanFR))")

    // 3. The base warp model alone, and the camera-sensor score.
    let config = InferenceConfig()
    let warp = try WarpInference.run(cgImage: cg, config: config)
    Show.step(3, "sensor", "the warp tile model (200 trees, depth 8, 19 features) scores every tile: P(generated) per tile, every second shown")
    Show.map(warp)
    let n = warp.gridRows * warp.gridCols
    let raw = warp.sensorRawProbability ?? 0
    let contract = warp.sensorCalibration!
    let cuts = contract.cuts!
    Show.line("tile vote: \(Int((raw * Float(n)).rounded())) of \(n) tiles above 0.5 → the camera-sensor score \(Show.f(raw))")
    Show.line("two cuts on the vote: real at or under \(Show.f(Float(cuts.realAtOrBelow))), generated at or over \(Show.f(Float(cuts.generatedAtOrAbove))), inconclusive between")
    Show.line("→ \(warp.sensorPrediction ?? "?"), trust \(Trust.sensorVote(warp, route: "camera"))")
    Show.line("weighted warp score \(Show.f(warp.weightedScore)) against 0.56 ± 0.04 → \(warp.weightedPrediction)")
    let (warpWorst, warpMismatches) = try Golden.compare(try ResultJSON.encode(warp, times: [], device: "gpu"),
                                                         try Data(contentsOf: Images.goldens.appendingPathComponent("crop_ben.score.json")), tolerance: 0)
    checks.record("the warp lens's JSON equals Garde's leaf for leaf but for the sensor fields the cuts changed, with Garde's call (\(first.name))",
                  warpMismatches.isEmpty && warpWorst == 0 && warp.sensorProbability == raw)
    if !sample.isEmpty {
        Show.line("")
        Show.line("the camera-sensor score on the final_mixed sample (physics alone, no semantics):")
        Show.line("image".padding(toLength: 28, withPad: " ", startingAt: 0) + "truth      sensor p  call          trust  capture")
        for image in sample {
            let r = try WarpInference.run(cgImage: try ImageDecoding.cgImage(contentsOf: image.url), config: config)
            let truth = image.label == 0 ? "camera" : "generated"
            Show.line(image.name.padding(toLength: 28, withPad: " ", startingAt: 0) + truth.padding(toLength: 11, withPad: " ", startingAt: 0)
                      + Show.f(r.sensorProbability ?? 0) + "    " + (r.sensorPrediction ?? "?").padding(toLength: 14, withPad: " ", startingAt: 0)
                      + Trust.sensorVote(r, route: "camera").padding(toLength: 7, withPad: " ", startingAt: 0)
                      + (r.captureSignature.map { $0.present ? "present" : ($0.valid ? "absent" : "invalid") } ?? "?"))
            LensRuntime.releaseMemory()
        }
        Show.line("trust is high only for a binary call on a native camera route with a present capture signature that the weighted verdict agrees with")
        Show.line("(trust law v1): the sensor score is a camera detector, not a generator detector; the fusion and the specialists catch generators")
    }

    // 4. The capture signature and the screenshot gate.
    let capture = CaptureLens.features(cg)
    let gate = ScreenshotLens.gate(cg)
    Show.step(4, "capture", "native Nyquist peak \(Show.f(capture.peak, 1)) (present at ≥ 30 when the short side ≥ 512): \(capture.signature.present ? "a real sensor's mosaic is present" : "absent")")
    Show.line("screenshot gate: grad_zero \(Show.f(gate.gradZero, 3)), flat_strict \(Show.f(gate.flatStrict, 3)), top_color \(Show.f(gate.topColor, 3)) → \(gate.isScreenshot ? "screenshot" : "not a screenshot")")

    // 5. The fusion head: the camera base expert.
    let embedding = try SemanticLens.fusionEmbedding(cg)
    let s = warp.sharpness!
    let vector = [warp.weightedScore] + embedding + capture.asVector + [s.salientSharp, s.globalSharp, s.sharpRatio]
    let fusionHead = try TreeModelCache.shared.model(bundle.url(.fusionHead)!)
    let baseP = fusionHead.predict(vector)
    Show.step(5, "fusion", "warp weighted \(Show.f(warp.weightedScore)) ⊕ DINOv2 CLS (384) ⊕ capture (9) ⊕ sharpness (3) = \(vector.count) columns")
    Show.line("→ the fusion head (940 trees: the frozen reference's 900 plus 40 warm-start trees) → base P(AI) \(Show.f(baseP)) at 0.5 ± 0.04")

    // 6. The stacked specialists and the full verdict.
    let routed = try Detector.shared.detect(cgImage: cg, config: config)
    let r = routed.result
    Show.step(6, "specialists", "domain \(routed.domain.rawValue); the stack compounds on the base expert:")
    for c in r.specialists ?? [] { Show.line("  " + c.name.padding(toLength: 16, withPad: " ", startingAt: 0) + "P(AI) \(Show.f(c.pAI))  \(c.verdict.padding(toLength: 12, withPad: " ", startingAt: 0)) weight \(Show.f(c.weight, 2))") }
    if let comb = HeadRegistry.shared.combiner(in: config.bundle), !(r.captureSignature?.present ?? false) {
        let norm = try SemanticLens.normalizedEmbedding(cg)
        let heads = HeadKind.combinerOrder.map { HeadRegistry.shared.head($0, in: config.bundle)!.pAI(norm) }
        let np = NoiseprintLens.score(cg)
        let ls = comb.headLogits(heads, pairAI: nil)
        var z = comb.w0 + comb.wBase * comb.lg(baseP, comb.capBase)
        Show.line("the combiner, term by term (capture absent, so it runs):")
        Show.line(String(format: "  w0 %.4f + w_base %.4f · lg(base %.4f) %.4f", comb.w0, comb.wBase, baseP, comb.lg(baseP, comb.capBase)))
        for (k, kind) in HeadKind.combinerOrder.enumerated() {
            z += comb.wGen[k] * max(0, ls[k])
            Show.line(String(format: "  + w_gen[%@] %.4f · max(0, lg %.4f)", kind.rawValue, comb.wGen[k], ls[k]))
        }
        if baseP < comb.gateCeiling {
            let rescue = comb.wRescue * max(0, -(ls.max() ?? -comb.capHead))
            let camera = (comb.wNp ?? 0) * max(0, comb.lg(np ?? 0.5, comb.capHead))
            z -= rescue + camera
            Show.line(String(format: "  − rescue %.4f − noiseprint %.4f   (base below the 0.75 gate)", rescue, camera))
        } else {
            Show.line(String(format: "  base %.4f ≥ the 0.75 gate: no rescue, no noiseprint term", baseP))
        }
        let pooled = 1 / (1 + exp(-z))
        Show.line(String(format: "  z = %.4f → pooled P(AI) %.4f", z, pooled))
        checks.record("the hand-computed pool equals the router's pre-semantic score", abs(pooled - (r.routeDiagnostics?.preSemanticP ?? -1)) < 1e-6)
    }
    Show.line("verdict: weighted \(Show.f(r.weightedScore)) \(r.weightedPrediction); majority (camera-sensor) \(Show.f(r.majorityScore)) \(r.majorityPrediction), trust \(Trust.physicsVote(r))")
    for crop in crops {
        let routedCrop = try Detector.shared.detect(cgImage: try ImageDecoding.cgImage(contentsOf: crop.url), config: config)
        let ours = try ResultJSON.encode(routedCrop.result, times: [], device: "route", route: routedCrop.domain.rawValue)
        let (worst, mismatches) = try Golden.compare(ours, try Data(contentsOf: crop.gardeRoute!), tolerance: 1e-4)
        checks.record("the routed result matches Garde's for \(crop.name) but for the sensor fields the cuts changed: labels exact, numbers within 1e-4 (max |Δ| \(String(format: "%.2g", worst)))", mismatches.isEmpty)
    }

    // 7. The training regime in miniature: the recipe DSL, the plan, the engine, a candidate bundle.
    Show.step(7, "train", "the training regime in miniature, on the code paths `veilgarde train` runs")
    let made = try Toy.writeDataset(sample)
    let rows = try Toy.writeStore()
    Show.line("dataset: \(made)")
    Show.line("store:   \(rows)")
    let recipe = TrainingRecipe(id: "playground") {
        WarpTileModel(dataset: Toy.dataset).trees(20).depth(4)       // the toy warp tile model
        FusionHead().warmStart(add: 2, eta: 0.03)                    // the flywheel's only base move
        DinoHead(.human)                                             // one atlas head, the shipped recipe
        Combiner()                                                   // pooled over the candidate's heads
    }
    Show.line("the recipe, as Swift:  WarpTileModel(…).trees(20).depth(4) · FusionHead().warmStart(add: 2) · DinoHead(.human) · Combiner()")
    let engine = TrainingEngine(area: Scratch.workArea, parent: ShippedBundle.directory, store: Toy.store) { event in
        if let line = event.line { Show.line("  · " + line) }
    }
    engine.replace = true
    let plan = try engine.plan(recipe)
    Show.line("the plan (no MLX, no writes):")
    for line in plan.summary.split(separator: "\n") { Show.line("  " + line) }
    let outcome = try engine.train(recipe)
    var candidate = outcome.candidate
    Show.line("these are toy fits (a dozen images, a few hundred rows), so their numbers mean little: a toy separates its own images")
    Show.line("perfectly and a weight can run away; `veilgarde train …` runs the same code on final_mixed and the whole store")

    // The toy warp model is an XGBoost JSON Frigate's evaluator reads unchanged.
    let toyURL = candidate.url(.warpTile)!
    let toy = try GBDTModel.load(toyURL)
    let frigate = try TreeModelCache.shared.model(toyURL)          // Frigate's XGBoostTreeModel
    let shards = try TileCache(directory: Scratch.work.appendingPathComponent("store/tiles/dataset")).load()
    let toyTiles = TileSet.gather(shards, partitions: [.train, .val])
    let rowsF = (0..<toyTiles.tileCount).map { toyTiles.data.row($0) }
    checks.record("the toy warp model (\(toy.trees.count) trees) reads back through Frigate's evaluator with identical predictions on \(rowsF.count) tiles",
                  rowsF.allSatisfy { frigate.predict($0) == toy.predict($0) })

    // Its calibration, by hand: too few images for the engine's floors (25 and 15 per class).
    let scores = WarpTrainer.imageScores(toy, toyTiles)
    let toyPlatt = Platt.fit(labels: toyTiles.images.map(\.label), probabilities: scores.majority.map(Double.init))
    let calibrated = Platt.apply(scores.majority.map(Double.init), toyPlatt)
    let choice = try OperatingThreshold.choose(labels: toyTiles.images.map(\.label), probabilities: calibrated, maxRealFPR: 0.25)
    let toySHA = candidate.manifest.artifact(.warpMajoritySensor)!.sha256
    let fitted = try SensorCalibrationContract(sensorVariant: "warp19", sensorModelSHA256: toySHA, transform: .platt, plattPayload: toyPlatt,
                                               decisionThreshold: Float(choice.threshold), uncertainBand: 0.04)
    let file = SensorCalibrationFile.twoCuts(from: fitted)!          // where the fitted Platt changes its call
    let data = try JSONCoding.prettyEncoder().encode(file)
    try candidate.put(data, as: "calibration/warp_sensor_calibration.json", role: .sensorCalibration)
    Show.line(String(format: "Platt by hand on %d images' tile votes: σ(%.3f · logit(f) %+.3f), threshold %.3f (recall %.2f at real FPR ≤ 0.25)",
                     toyTiles.images.count, toyPlatt.coef, toyPlatt.intercept, choice.threshold, choice.generatedRecall))
    let (lo, hi) = (file.cuts!.realAtOrBelow, file.cuts!.generatedAtOrAbove)   // a cut outside [0, 1] never fires
    Show.line("said as two cuts on the vote, as the engine writes it: " + (lo < 0 ? "never real" : String(format: "real at or under %.4f", lo)) + ", "
              + (hi > 1 ? "never generated" : String(format: "generated at or over %.4f", hi)))
    let bound = (try? SensorCalibrationContract.decode(data, expectedModelSHA256: toySHA, expectedSensorVariant: "warp19")) != nil
    let unbound = (try? SensorCalibrationContract.decode(data, expectedModelSHA256: bundle.sha256(.warpTile)!, expectedSensorVariant: "warp19")) == nil
    checks.record("the toy calibration contract binds to the toy model's bytes and refuses the shipped model's", bound && unbound)

    // The warm start: the shipped fusion head's 940 trees, untouched, and two more.
    let shippedHead = try GBDTModel.load(bundle.url(.fusionHead)!)
    let warm = try GBDTModel.load(candidate.url(.fusionHead)!)
    let untouched = zip(shippedHead.trees, warm.trees).allSatisfy { $0.raw == $1.raw }
    checks.record("the warm start keeps the shipped fusion head's \(shippedHead.trees.count) trees byte for byte and adds \(warm.trees.count - shippedHead.trees.count)",
                  untouched && warm.trees.count == shippedHead.trees.count + 2)

    // The trained human head beside the shipped one, on the parity crops.
    let human = try LinearHead.load(candidate.url(.head, head: .human)!)
    let shippedHuman = HeadRegistry.shared.head(.human, in: config.bundle)!
    for crop in crops {
        let norm = try SemanticLens.normalizedEmbedding(try ImageDecoding.cgImage(contentsOf: crop.url))
        Show.line("\(crop.name): human head P(AI) \(Show.f(human.pAI(norm))) trained here, \(Show.f(shippedHuman.pAI(norm))) shipped")
    }
    var verified = true
    do { try candidate.verify() } catch { verified = false }
    checks.record("the candidate bundle verifies (\(candidate.manifest.artifacts.count) artifacts, every hash): \(candidate.root.path)", verified)
    Show.line("run it:  scripts/cli.sh route Tests/VeilGardeInferenceTests/Fixtures/garde/crop_ben.png --bundle Playground/.work/candidates/playground")

    // 8. The flywheel: the specialist regime alone, on Playground/.work.
    Show.step(8, "flywheel", "the specialist regime alone: a live bundle, a battery, a promote and its rollback, all in Playground/.work")
    let fly = FlywheelArea(Scratch.workArea)
    try? FileManager.default.removeItem(at: fly.live)
    try? FileManager.default.removeItem(at: fly.battery)
    // A regression battery: every image keeps the call the shipped detector gives it today.
    let shippedVerdicts = DetectorVerdicts(bundle: .shipped)
    var keepsReal: [String] = [], keepsGenerated: [String] = []
    for image in crops + sample {
        let v = try shippedVerdicts.verdict(for: image.url)
        if v.weighted == "real" { keepsReal.append(image.url.path) } else if v.weighted == "generated" { keepsGenerated.append(image.url.path) }
    }
    let spec = BatterySpec(groups: [
        .init(name: "keeps_real", mode: .hard, want: "real", paths: keepsReal),
        .init(name: "keeps_generated", mode: .hard, want: "generated", paths: keepsGenerated),
    ])
    let floors = ["keeps_real": BatteryGroupResult(acc: 1, n: keepsReal.count, expectedN: nil, inputComplete: nil, semAcc: nil, mode: .hard, want: "real"),
                  "keeps_generated": BatteryGroupResult(acc: 1, n: keepsGenerated.count, expectedN: nil, inputComplete: nil, semAcc: nil, mode: .hard, want: "generated")]
    try fly.initialize(from: try ShippedBundle.verified(), spec: try JSONEncoder().encode(spec), baseline: try JSONEncoder().encode(floors),
                       note: "the playground's live bundle")
    Show.line("live: the shipped bundle copied to \(fly.live.path)")
    Show.line("battery: \(keepsReal.count) images that must stay real and \(keepsGenerated.count) that must stay generated (HARD groups)")
    let liveBefore = try fly.liveHashes()
    let frozenBefore = try fly.liveBundle().manifest.artifacts.filter(\.frozen).map(\.sha256)
    let battery: Promoter.Battery = { gate, root in
        let report = try BatteryRunner.run(spec: try BatterySpec.load(fly.batterySpec), specURL: fly.batterySpec, gate: gate,
                                           baselineURL: fly.batteryBaseline, verdicts: DetectorVerdicts(bundle: try DetectorBundle.load(root)))
        for line in report.table.split(separator: "\n") { Show.line("  " + line) }
        return report
    }
    let promoter = Promoter(area: fly, battery: battery) { Show.line("  · " + $0) }
    do {
        _ = try FlywheelSlot(parsing: "warp-tile")
        checks.record("promote refuses the frozen warp tile model", false)
    } catch {
        checks.record("promote refuses the frozen warp tile model (\(error))", true)
    }
    Show.line("promote the human head step 7 trained, behind admission and the full battery:")
    do {
        let record = try promoter.promote(.head(.human), from: candidate.root, store: FeatureStore(directory: fly.store))
        Show.line("promoted: \(record.fromSHA256?.prefix(12) ?? "?") → \(record.toSHA256?.prefix(12) ?? "?"); now roll it back")
        try promoter.rollback(to: record.snapshot!)
    } catch {
        Show.line("not promoted: \(error); live was left as it was")
    }
    for line in try String(contentsOf: fly.promoteLog, encoding: .utf8).split(separator: "\n") {
        if let row = try? JSONCoding.decoder().decode(PromotionRecord.self, from: Data(line.utf8)) { Show.line("  log: \(row.kind.rawValue) \(row.slot)" + (row.battery.map { " (battery \($0))" } ?? "")) }
    }
    let frozenAfter = try fly.liveBundle().manifest.artifacts.filter(\.frozen).map(\.sha256)
    checks.record("the frozen artifacts' bytes never moved (\(frozenBefore.count) of them)", frozenAfter == frozenBefore)
    checks.record("live is byte for byte what it was before the promote", try fly.liveHashes() == liveBefore)
    Show.line("look at it:  scripts/cli.sh flywheel status --work-area Playground/.work")

    // 9. The watermark: the same residual, read as a signature.
    let markImage = try ImageDecoding.cgImage(contentsOf: crops[0].url)
    let signature = try Watermark.sign(markImage)
    Show.step(9, "watermark", "\(crops[0].name) signed by its fragility pattern: \(signature.rows)×\(signature.cols) tiles, \(signature.codes.count) sections of 4×4, \(signature.measuredBits) bits")
    Show.line("each tile's 4 bits: is its fragility rate above its east, south, south-east and north-east neighbours'? (ordinal, so gain-proof)")
    Show.line("signature: \(signature.compact.prefix(64))… (\(signature.binary.count) bytes, cid \(signature.cid.prefix(16)))")
    let me = try Watermark.match(markImage, against: signature, options: MatchOptions(phases: [0]))
    checks.record("the image matches its own signature at offset (0, 0) with score \(Show.f(Float(me.score), 3))", me.matched && me.score == 1 && me.offsetX == 0 && me.offsetY == 0)
    var rng = SplitMix64(seed: 19)
    let side = Int(Double(markImage.width) * 0.5.squareRoot())
    let cx = rng.index(markImage.width - side), cy = rng.index(markImage.height - side)
    if let crop = ImageLoading.renderCrop(markImage, CGRect(x: cx, y: cy, width: side, height: side)) {
        let r = try Watermark.match(crop, against: signature)
        let error = Double(max(abs(r.pixelX - cx), abs(r.pixelY - cy))) / 32
        Show.line(String(format: "a half-area crop at (%d, %d) px: %@, score %.3f over %d bits (z %.1f), found at (%d, %d), off by %.2f tiles",
                         cx, cy, r.matched ? "matched" : "not matched", r.score, r.bitsCompared, r.zScore, r.pixelX, r.pixelY, error))
        let jpegMatch = try Watermark.match(try ImageCodec.recompressed(markImage, as: .jpeg, quality: 0.75), against: signature, options: MatchOptions(phases: [0]))
        Show.line(String(format: "the image re-encoded as JPEG q75: %@, score %.3f", jpegMatch.matched ? "matched" : "not matched", jpegMatch.score))
        Show.line("(reported, not asserted: whether v1 holds on real crops is `veilgarde watermark accept`'s question)")
    }

    // 10. Every checkpoint.
    Show.step(10, "verify", "\(checks.all.filter(\.1).count) of \(checks.all.count) checkpoints hold")
}

do {
    try run()
} catch {
    print("playground: \(error)")
    exit(1)
}
exit(checks.passed ? 0 : 1)
