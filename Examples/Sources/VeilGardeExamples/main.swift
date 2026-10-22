//
//  main.swift
//  VeilGardeExamples
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: VeilGarde end to end, top to bottom, in its two lanes. The detector first, one part at a
//        time: the capture signature and the screenshot gate, DINOv2's two views of the image, the
//        camera head's 393-column row and its P(AI), then every member of the stack and the
//        revisions, the combiner's arithmetic printed term by term. Then the training regime in
//        miniature (step 6: a recipe, its plan, the engine, a candidate bundle), the flywheel loop
//        (step 7: a live bundle, a battery, a promote and its rollback), and the other lane, the
//        watermark (step 8: a signature read off the warp residual, matched by a crop and a
//        re-encode). Every step that has a golden checks itself against it.
//  IN:   The DINOv2 weights in the work area or VEILGARDE_WEIGHTS; final_mixed under
//        VEILGARDE_DATASETS for the iPhone sample (optional). Run by Examples/run.sh.
//  OUT:  One numbered block per step; Examples/.work for the training steps. Exit 0 only when
//        every checkpoint holds.
//  PIN:  One MLX workload at a time; everything runs on this thread. The result is held to
//        VeilGarde's own goldens with labels exact and numbers within 1e-4 (Frigate's Metal kernels
//        move DINOv2 by about 1e-5).
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
    Show.step(1, "images", "\(crops.count) parity crops with VeilGarde's goldens" + (sample.isEmpty ? "; the T9 is not mounted, no iPhone sample" : "; \(sample.count) from final_mixed (\(sample.filter { $0.label == 0 }.count) iPhone originals, \(sample.filter { $0.label == 1 }.count) generated)"))
    let first = crops[0]
    let cg = try ImageDecoding.cgImage(contentsOf: first.url)
    let config = InferenceConfig()

    // 2. Whether a sensor made it: the capture signature, and the screenshot gate.
    let capture = CaptureLens.features(cg)
    let gate = ScreenshotLens.gate(cg)
    Show.step(2, "capture", "\(first.name): native Nyquist peak \(Show.f(capture.peak, 1)) (present at ≥ 30 when the short side ≥ 512): \(capture.signature.present ? "a real sensor's mosaic is present" : "absent")")
    Show.line("screenshot gate: grad_zero \(Show.f(gate.gradZero, 3)), flat_strict \(Show.f(gate.flatStrict, 3)), top_color \(Show.f(gate.topColor, 3)) → \(gate.isScreenshot ? "screenshot" : "not a screenshot")")

    // 3. What it depicts: DINOv2's two views.
    let embedding = try SemanticLens.fusionEmbedding(cg)
    let norm = try SemanticLens.normalizedEmbedding(cg)
    func l2(_ v: [Float]) -> Float { v.map { $0 * $0 }.reduce(0, +).squareRoot() }
    Show.step(3, "semantics", "DINOv2-small, two views of the same image, 384 numbers each")
    Show.line("the camera view (short edge 256, centre crop 224): norm \(Show.f(l2(embedding), 2)), first values " + embedding.prefix(4).map { Show.f($0) }.joined(separator: " "))
    Show.line("the heads' view (force-resized to 360×640):           norm \(Show.f(l2(norm), 2)), first values " + norm.prefix(4).map { Show.f($0) }.joined(separator: " "))

    // 4. The camera head: the camera member's row and its P(AI).
    let cameraHead = try TreeModelCache.shared.model(bundle.url(.camera)!)
    let row = CameraRow(dino: embedding, capture: capture).asVector
    let cameraP = cameraHead.predict(row)
    let r = try Detector.detect(cgImage: cg, config: config)
    let shippedTrees = try GBDTModel.load(bundle.url(.camera)!).trees.count
    Show.step(4, "camera", "DINOv2 CLS (384) ⊕ capture (9) = \(row.count) columns through the camera head (\(shippedTrees) trees)")
    Show.line("→ the camera member's P(AI) \(Show.f(cameraP)) at 0.5 ± 0.04: \(config.decision.label(cameraP))")
    checks.record("the camera row built by hand gives the camera member's P(AI)", abs(cameraP - (r.stack.member("camera")?.p ?? -1)) < 1e-6)

    // 5. Every member of the stack, then the revisions.
    Show.step(5, "stack", "every member speaks on its own; then the revisions read them:")
    for m in r.stack {
        Show.line("  " + m.name.padding(toLength: 16, withPad: " ", startingAt: 0) + "P(AI) " + (m.p.map { Show.f($0) } ?? "  —   ") + "  " + m.verdict)
    }
    for v in r.revisions {
        Show.line("  revision " + v.name.padding(toLength: 13, withPad: " ", startingAt: 0) + (v.applied ? "applied" : "skipped") + "  P(AI) \(Show.f(v.p))  \(v.prediction)")
    }
    if let comb = HeadRegistry.shared.combiner(in: config.bundle), r.stack.member("capture")?.flag("present") == false, !gate.isScreenshot {
        let evidence = comb.evidenceMembers.map { r.stack.member($0)!.p! }
        let ls = comb.evidenceLogits(evidence)
        var z = comb.w0 + comb.anchor.w * comb.lg(cameraP, comb.anchor.cap)
        Show.line("the combiner revision, term by term (capture absent and the gate quiet, so it pools around the camera member):")
        Show.line(String(format: "  w0 %.4f + anchor %.4f · lg(camera %.4f) %.4f", comb.w0, comb.anchor.w, cameraP, comb.lg(cameraP, comb.anchor.cap)))
        for (k, member) in comb.evidenceMembers.enumerated() {
            z += comb.evidence[k].w * max(0, ls[k])
            Show.line(String(format: "  + %@ %.4f · max(0, lg %.4f)", member, comb.evidence[k].w, ls[k]))
        }
        if cameraP < comb.anchor.gateCeiling {
            let rescue = comb.rescue.w * max(0, -(ls.max() ?? -comb.evidenceCap))
            z -= rescue
            Show.line(String(format: "  − rescue %.4f   (the camera member below the 0.75 gate)", rescue))
        } else {
            Show.line(String(format: "  camera %.4f ≥ the 0.75 gate: no rescue", cameraP))
        }
        let pooled = 1 / (1 + exp(-z))
        Show.line(String(format: "  z = %.4f → pooled P(AI) %.4f", z, pooled))
        checks.record("the hand-computed pool equals the combiner revision's P(AI)", abs(pooled - (r.revisions.revision("combiner")?.p ?? -1)) < 1e-6)
    }
    Show.line("verdict: P(AI) \(Show.f(r.p)) → \(r.prediction)")
    for crop in crops {
        let result = try Detector.detect(cgImage: try ImageDecoding.cgImage(contentsOf: crop.url), config: config)
        let ours = try ResultJSON.encode(result, times: [], device: "route")
        let (worst, mismatches) = try Golden.compare(ours, try Data(contentsOf: crop.golden!), tolerance: 1e-4)
        checks.record("the result matches VeilGarde's golden for \(crop.name): labels exact, numbers within 1e-4 (max |Δ| \(String(format: "%.2g", worst)))", mismatches.isEmpty)
    }
    if !sample.isEmpty {
        Show.line("")
        Show.line("the full detector on the final_mixed sample:")
        Show.line("image".padding(toLength: 28, withPad: " ", startingAt: 0) + "truth      camera   P(AI)    call          capture")
        for image in sample {
            let ri = try Detector.detect(cgImage: try ImageDecoding.cgImage(contentsOf: image.url), config: config)
            let truth = image.label == 0 ? "camera" : "generated"
            Show.line(image.name.padding(toLength: 28, withPad: " ", startingAt: 0) + truth.padding(toLength: 11, withPad: " ", startingAt: 0)
                      + Show.f(ri.stack.member("camera")?.p ?? 0) + "   " + Show.f(ri.p) + "   " + ri.prediction.padding(toLength: 14, withPad: " ", startingAt: 0)
                      + (ri.stack.member("capture")?.verdict ?? "?"))
            LensRuntime.releaseMemory()
        }
    }

    // 6. The training regime in miniature: the recipe DSL, the plan, the engine, a candidate bundle.
    Show.step(6, "train", "the training regime in miniature, on the code paths `veilgarde train` runs")
    let rows = try Toy.writeStore()
    Show.line("store: \(rows)")
    let recipe = TrainingRecipe(id: "examples") {
        CameraHead().warmStart(add: 2, eta: 0.03)                    // the flywheel's only camera move
        SpecialistHead(.human)                                       // one category head, the shipped recipe
        Combiner()                                                   // pooled over the candidate's heads
    }
    Show.line("the recipe, as Swift:  CameraHead().warmStart(add: 2) · SpecialistHead(.human) · Combiner()")
    let engine = TrainingEngine(area: Scratch.workArea, parent: ShippedBundle.directory, store: Toy.store) { event in
        if let line = event.line { Show.line("  · " + line) }
    }
    engine.replace = true
    let plan = try engine.plan(recipe)
    Show.line("the plan (no writes):")
    for line in plan.summary.split(separator: "\n") { Show.line("  " + line) }
    let outcome = try engine.train(recipe)
    let candidate = outcome.candidate
    Show.line("these are toy fits (a few hundred rows), so their numbers mean little; `veilgarde train …` runs the same code on the whole store")

    // The warm start: the shipped camera head's trees, untouched, and two more.
    let shippedHead = try GBDTModel.load(bundle.url(.camera)!)
    let warm = try GBDTModel.load(candidate.url(.camera)!)
    let untouched = zip(shippedHead.trees, warm.trees).allSatisfy { $0.raw == $1.raw }
    checks.record("the warm start keeps the shipped camera head's \(shippedHead.trees.count) trees byte for byte and adds \(warm.trees.count - shippedHead.trees.count)",
                  untouched && warm.trees.count == shippedHead.trees.count + 2)
    // The candidate's head is XGBoost JSON Frigate's evaluator reads unchanged.
    let frigate = try TreeModelCache.shared.model(candidate.url(.camera)!)
    let width = CameraRow.width
    let storeRows = try FeatureStore(directory: Toy.store).select(columns: Set(CameraRow.columns))
    let flat = storeRows.matrix(CameraRow.columns)
    let cameraRows = (0..<storeRows.count).map { Array(flat[($0 * width)..<(($0 + 1) * width)]) }
    checks.record("the candidate's camera head reads back through Frigate's evaluator with identical predictions on \(cameraRows.count) store rows",
                  cameraRows.allSatisfy { frigate.predict($0) == warm.predict($0) })

    // The trained human head beside the shipped one, on the parity crops.
    let human = try LinearHead.load(candidate.url(.head, head: .human)!)
    let shippedHuman = HeadRegistry.shared.head(.human, in: config.bundle)!
    for crop in crops {
        let n = try SemanticLens.normalizedEmbedding(try ImageDecoding.cgImage(contentsOf: crop.url))
        Show.line("\(crop.name): human head P(AI) \(Show.f(human.pAI(n))) trained here, \(Show.f(shippedHuman.pAI(n))) shipped")
    }
    var verified = true
    do { try candidate.verify() } catch { verified = false }
    checks.record("the candidate bundle verifies (\(candidate.manifest.artifacts.count) artifacts, every hash): \(candidate.root.path)", verified)
    Show.line("run it:  scripts/cli.sh route Tests/VeilGardeInferenceTests/Fixtures/crops/crop_ben.png --bundle Examples/.work/candidates/examples")

    // 7. The flywheel, on Examples/.work.
    Show.step(7, "flywheel", "the flywheel alone: a live bundle, a battery, a promote and its rollback, all in Examples/.work")
    let fly = FlywheelArea(Scratch.workArea)
    try? FileManager.default.removeItem(at: fly.live)
    try? FileManager.default.removeItem(at: fly.battery)
    // A regression battery: every image keeps the call the shipped detector gives it today.
    let shippedVerdicts = DetectorVerdicts(bundle: .shipped)
    var keepsReal: [String] = [], keepsGenerated: [String] = []
    for image in crops + sample {
        let v = try shippedVerdicts.verdict(for: image.url)
        if v.prediction == "real" { keepsReal.append(image.url.path) } else if v.prediction == "generated" { keepsGenerated.append(image.url.path) }
    }
    var groups: [BatterySpec.Group] = [.init(name: "keeps_real", mode: .hard, want: "real", paths: keepsReal)]
    var floors = ["keeps_real": BatteryGroupResult(acc: 1, n: keepsReal.count, expectedN: nil, inputComplete: nil, semAcc: nil, mode: .hard, want: "real")]
    if !keepsGenerated.isEmpty {
        groups.append(.init(name: "keeps_generated", mode: .hard, want: "generated", paths: keepsGenerated))
        floors["keeps_generated"] = BatteryGroupResult(acc: 1, n: keepsGenerated.count, expectedN: nil, inputComplete: nil, semAcc: nil, mode: .hard, want: "generated")
    }
    try fly.initialize(from: try ShippedBundle.verified(), spec: try JSONEncoder().encode(BatterySpec(groups: groups)), baseline: try JSONEncoder().encode(floors),
                       note: "the examples' live bundle")
    Show.line("live: the shipped bundle copied to \(fly.live.path)")
    Show.line("battery: \(keepsReal.count) images that must stay real and \(keepsGenerated.count) that must stay generated (HARD groups)")
    let liveBefore = try fly.liveHashes()
    let weightsBefore = try fly.liveBundle().manifest.weights
    let battery: Promoter.Battery = { gate, root in
        let report = try BatteryRunner.run(spec: try BatterySpec.load(fly.batterySpec), specURL: fly.batterySpec, gate: gate,
                                           baselineURL: fly.batteryBaseline, verdicts: DetectorVerdicts(bundle: try DetectorBundle.load(root)))
        for line in report.table.split(separator: "\n") { Show.line("  " + line) }
        return report
    }
    let promoter = Promoter(area: fly, battery: battery) { Show.line("  · " + $0) }
    for name in ["dinov2-small", "fusion-head"] {
        do {
            _ = try FlywheelSlot(parsing: name)
            checks.record("promote refuses \(name)", false)
        } catch {
            checks.record("promote refuses \(name) (\(error))", true)
        }
    }
    Show.line("promote the human head step 6 trained, behind admission and the full battery:")
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
    checks.record("the frozen weights never moved (\(weightsBefore.count) of them)", try fly.liveBundle().manifest.weights == weightsBefore)
    checks.record("live is byte for byte what it was before the promote", try fly.liveHashes() == liveBefore)
    Show.line("look at it:  scripts/cli.sh flywheel status --work-area Examples/.work")

    // 8. The other lane: the watermark, read off the warp residual.
    let markImage = try ImageDecoding.cgImage(contentsOf: crops[0].url)
    let signature = try Watermark.sign(markImage)
    Show.step(8, "watermark", "\(crops[0].name) signed by its fragility pattern: \(signature.rows)×\(signature.cols) tiles, \(signature.codes.count) sections of 4×4, \(signature.measuredBits) bits")
    Show.line("each 32-px tile warped through 16 fixed homographies at two strengths and back; its fragility rate is how much faster the stronger warps' residual grows")
    Show.line("each tile's 4 bits: is its fragility rate above its east, south, south-east and north-east neighbours'? (ordinal, so gain-proof)")
    Show.line("signature: \(signature.compact.prefix(64))… (\(signature.binary.count) bytes, cid \(signature.cid.prefix(16)))")
    let me = try Watermark.match(markImage, against: signature, options: MatchOptions(phases: [0]))
    checks.record("the image matches its own signature at offset (0, 0) with score \(Show.f(Float(me.score), 3))", me.matched && me.score == 1 && me.offsetX == 0 && me.offsetY == 0)
    var rng = SplitMix64(seed: 19)
    let side = Int(Double(markImage.width) * 0.5.squareRoot())
    let cx = rng.index(markImage.width - side), cy = rng.index(markImage.height - side)
    if let crop = ImageLoading.renderCrop(markImage, CGRect(x: cx, y: cy, width: side, height: side)) {
        let m = try Watermark.match(crop, against: signature)
        let error = Double(max(abs(m.pixelX - cx), abs(m.pixelY - cy))) / 32
        Show.line(String(format: "a half-area crop at (%d, %d) px: %@, score %.3f over %d bits (z %.1f), found at (%d, %d), off by %.2f tiles",
                         cx, cy, m.matched ? "matched" : "not matched", m.score, m.bitsCompared, m.zScore, m.pixelX, m.pixelY, error))
        let jpegMatch = try Watermark.match(try ImageCodec.recompressed(markImage, as: .jpeg, quality: 0.75), against: signature, options: MatchOptions(phases: [0]))
        Show.line(String(format: "the image re-encoded as JPEG q75: %@, score %.3f", jpegMatch.matched ? "matched" : "not matched", jpegMatch.score))
        Show.line("(reported, not asserted: whether v1 holds on real crops is `veilgarde watermark accept`'s question)")
    }

    // 9. Every checkpoint.
    Show.step(9, "verify", "\(checks.all.filter(\.1).count) of \(checks.all.count) checkpoints hold")
}

do {
    try run()
} catch {
    print("examples: \(error)")
    exit(1)
}
exit(checks.passed ? 0 : 1)
