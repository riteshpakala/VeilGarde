//
//  Parity.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde parity`: the checks against the Python references. `warp` compares one tile's
//        residual maps with a cv2 fixture (dump_reference.py); `dirsig` compares the directional
//        signature with a v4_a1_tilesig fixture. Each prints a JSON report of max |Δ| for the
//        quantized and the exact-coordinate paths and exits 3 when the quantized path misses.
//        `dino` compares DINOv2 embeddings of HF-preprocessed pixels with the dino_parity_dump.py
//        references, isolating the ViT; with --images it runs the full Swift preprocessing on the
//        raw images too (the end-to-end check).
//  PIN:  Garde's --verify-warp, --verify-dirsig, --verify-dino and --verify-dino-e2e, with their
//        thresholds: warp < 1e-3; signature < 1e-3 on the 16 raw energies and < 5e-3 on the 5
//        log-ratios (log amplifies near-zero energies); ViT cosine ≥ 0.999; end to end ≥ 0.99.
//

import ArgumentParser
import Foundation
import VeilGarde

struct ParityCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parity", abstract: "Check the lens against the Python fixtures and against Garde.",
        subcommands: [Warp.self, Dirsig.self, Dino.self, Clip.self])

    static func floats(_ any: Any?) -> [Float]? { (any as? [Any])?.map { Float(($0 as? NSNumber)?.doubleValue ?? 0) } }

    static func report(_ values: [String: Double], pass: Bool) throws {
        try emitJSON(try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), to: "-")
        if !pass { throw ArgumentParser.ExitCode(FailureCode.parityMismatch.rawValue) }
    }

    struct Warp: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "warp", abstract: "Compare one tile's warp residual maps with a cv2 fixture ({tile, R_low, R_high}).")

        @Argument(help: "The fixture JSON.") var fixture: String

        func run() throws {
            guarded {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixture))) as? [String: Any]
                guard let tile = ParityCommand.floats(object?["tile"]), let low = ParityCommand.floats(object?["R_low"]), let high = ParityCommand.floats(object?["R_high"]) else {
                    throw VeilGardeFailure.data("\(fixture) is not a warp fixture ({tile, R_low, R_high})")
                }
                func maxDiff(_ a: [Float], _ b: [Float]) -> Double { Double(zip(a, b).map { abs($0 - $1) }.max() ?? .infinity) }
                var report = [String: Double]()
                for quantize in [true, false] {
                    let maps = WarpDebug.residualMaps(tileRGB: tile, quantizeLikeCV2: quantize)
                    let key = quantize ? "cv2_quantized" : "exact_double"
                    report["\(key)_low_maxdiff"] = maxDiff(maps.low, low)
                    report["\(key)_high_maxdiff"] = maxDiff(maps.high, high)
                }
                try ParityCommand.report(report, pass: (report["cv2_quantized_low_maxdiff"] ?? 1) < 1e-3 && (report["cv2_quantized_high_maxdiff"] ?? 1) < 1e-3)
            }
        }
    }

    struct Dirsig: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "dirsig", abstract: "Compare the directional signature with a v4_a1_tilesig fixture ({height, width, image, sig}).")

        @Argument(help: "The fixture JSON.") var fixture: String

        func run() throws {
            guarded {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixture))) as? [String: Any]
                guard let h = (object?["height"] as? NSNumber)?.intValue, let w = (object?["width"] as? NSNumber)?.intValue,
                      let img = ParityCommand.floats(object?["image"]), let sig = ParityCommand.floats(object?["sig"]) else {
                    throw VeilGardeFailure.data("\(fixture) is not a signature fixture ({height, width, image, sig})")
                }
                let tiles = (h / 32) * (w / 32)
                var report = [String: Double]()
                for quantize in [true, false] {
                    let got = WarpDebug.directionalSignature(imageRGB: img, height: h, width: w, quantizeLikeCV2: quantize)
                    var raw: Float = 0, derived: Float = 0
                    for t in 0..<tiles {
                        for f in 0..<DirectionalSignature.count {
                            let d = abs(got[t * 21 + f] - sig[t * 21 + f])
                            if f < 16 { raw = max(raw, d) } else { derived = max(derived, d) }
                        }
                    }
                    let key = quantize ? "cv2_quantized" : "exact_double"
                    report["\(key)_raw_maxdiff"] = Double(raw)
                    report["\(key)_derived_maxdiff"] = Double(derived)
                }
                try ParityCommand.report(report, pass: (report["cv2_quantized_raw_maxdiff"] ?? 1) < 1e-3 && (report["cv2_quantized_derived_maxdiff"] ?? 1) < 5e-3)
            }
        }
    }

    struct Dino: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "dino", abstract: "Compare DINOv2 embeddings with the dino_parity_dump.py references (<name>.pixels, <name>.emb).")

        @Argument(help: "The fixture safetensors.") var fixture: String
        @Option(help: "The raw images' folder, for the end-to-end check (bahamut.jpg, test1.png, IMG_4096.jpeg).") var images: String?
        @Option(help: "DINOv2 weights: small, xsmall or xxsmall.") var dino: String = DinoVariant.small.rawValue

        func run() throws {
            guarded {
                ShippedBundle.registerWeightFolders()
                guard let variant = DinoVariant(rawValue: dino) else { throw VeilGardeFailure.usage("--dino must be small, xsmall or xxsmall") }
                let file = try SafetensorsFile(url: URL(fileURLWithPath: (fixture as NSString).expandingTildeInPath))
                let bases = Set(file.names.filter { $0.hasSuffix(".pixels") }.map { String($0.dropLast(".pixels".count)) }).sorted()
                func cosine(_ a: [Float], _ b: [Float]) -> Float {
                    var dot: Float = 0, na: Float = 0, nb: Float = 0
                    for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
                    return dot / (na.squareRoot() * nb.squareRoot())
                }
                var allPass = true
                for base in bases {
                    let pixels = try file.float32("\(base).pixels"), reference = try file.float32("\(base).emb")
                    let cos = cosine(try SemanticLens.embedding(pixels: pixels, variant: variant), reference)
                    let pass = cos >= 0.999
                    allPass = allPass && pass
                    print(base.padding(toLength: 12, withPad: " ", startingAt: 0) + String(format: " vit cosine %.5f  ", cos) + (pass ? "PASS" : "FAIL"))
                }
                if let images {
                    for (base, name) in [("bahamut", "bahamut.jpg"), ("test1", "test1.png"), ("IMG_4096", "IMG_4096.jpeg")] {
                        let url = URL(fileURLWithPath: (images as NSString).expandingTildeInPath).appendingPathComponent(name)
                        guard let reference = try? file.float32("\(base).emb"), let cg = try? ImageDecoding.cgImage(contentsOf: url) else { print("\(base): missing"); continue }
                        let cos = cosine(try SemanticLens.fusionEmbedding(cg, variant: variant), reference)
                        let pass = cos >= 0.99
                        allPass = allPass && pass
                        print(base.padding(toLength: 12, withPad: " ", startingAt: 0) + String(format: " e2e cosine %.5f  ", cos) + (pass ? "PASS" : "FAIL"))
                    }
                }
                if !allPass { throw ArgumentParser.ExitCode(FailureCode.parityMismatch.rawValue) }
            }
        }
    }

    struct Clip: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "clip", abstract: "The CLIP vision tower against Hugging Face's embeddings on the same pixels (clip_parity.safetensors).")
        @Argument(help: "The fixture (default: Tests/VeilGardeLensTests/Fixtures/clip_parity.safetensors).") var fixture: String?
        @Option(help: "The image files the fixture's first rows came from, to also check the Swift preprocessing end to end.") var images: [String] = []

        func run() throws {
            guarded {
                ShippedBundle.registerWeightFolders()
                let url = fixture.map(datasetURL) ?? URL(fileURLWithPath: "Tests/VeilGardeLensTests/Fixtures/clip_parity.safetensors")
                let f = try SafetensorsFile(url: url)
                let pixels = try f.uint8("pixels"), expected = try f.float32("embeds")
                let n = try f.tensor("pixels").shape[0]
                let ours = try CLIPLens.shared.tower()(CLIPPreprocess.input(pixels: pixels, count: n)).asArray(Float.self)
                func cosine(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Float { zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
                var worst: Float = 1
                for i in 0..<n {
                    let c = cosine(ours[(i * 512)..<((i + 1) * 512)], expected[(i * 512)..<((i + 1) * 512)])
                    worst = min(worst, c)
                    print(String(format: "image %d: cosine %.7f (same pixels)", i, c))
                }
                for (i, path) in images.enumerated() where i < n {
                    let e = try CLIPLens.embedding(try loadImage(path))
                    print(String(format: "%@: cosine %.5f (decoded and preprocessed here, HF's PIL resize there)", (path as NSString).lastPathComponent,
                                 cosine(e[0..<512], expected[(i * 512)..<((i + 1) * 512)])))
                }
                print(String(format: "worst cosine on the same pixels: %.7f %@", worst, worst >= 0.999 ? "(≥ 0.999)" : "(below 0.999)"))
                if worst < 0.999 { throw ExitCode(1) }
            }
        }
    }
}
