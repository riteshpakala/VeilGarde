// swift-tools-version: 6.4
// SPDX-License-Identifier: GPL-3.0-only
// VeilGarde — an AI-generated-image detector and a crop-robust watermark, as one package anyone
// can train and run: a stack of independent members (the camera head over DINOv2 and the capture
// signature, the screenshot head, the specialist heads, the semantic tiles) and the revisions that
// read them, the trainers and the flywheel that grow them, and a watermark read off a
// perspective-warp residual.
//
// Five products: VeilGarde (everything), VeilGardeInference (the detector alone), VeilSeal
// (the signature alone), VeilGardeAudio (the watermark on audio alone) and the `veilgarde`
// executable. Nine targets, in layers:
//   VeilGardeCore       the domain, Foundation + Crypto only, Swift 6 strict: Support/ (JSON,
//                       hashing, failures, the work area, safetensors, seeded splits), Features/
//                       (capture 9, the screenshot gate, the camera row), Boost/ (GBDTModel: the
//                       XGBoost JSON codec and evaluator), Heads/ (linear heads, the stack
//                       combiner), Bundle/ (artifacts, the manifest, SHA-256 binding), Result/
//                       (members' outputs, revisions' records, the schema-v1 JSON, the verdict
//                       law, route batches), Store/ (the features-only store, its migration)
//   VeilGardeLens       the extractors, in the order a pixel travels: Image/, Capture/,
//                       Semantic/ (DINOv2, CLIP vision), Scoring/ (the weights' locator)
//                                  (MLX through Frigate's MLX products, never its umbrella; Swift 5)
//   VeilGardeInference  the detector as one pipeline, Decode → Shared Signals → Stack → Revisions
//                       → Result: Config/, Route/ (the signals, the Detector), Stack/ (the
//                       pipeline, the members), Revisions/, Bundle/ (the shipped artifacts, and
//                       FrigateBoost's evaluator through the Frigate umbrella)
//                                                                     (Swift 5 mode, resources)
//   VeilGardeTraining   the trainers: Data/, Extract/, Boost/ (a native GBDT), Linear/, Camera/,
//                       Heads/, Combiner/, Backbone/ (DINOv2 and CLIP imports), Recipe/ (the
//                       trainable members), Engine/, Artifacts/                  (Swift 5 mode)
//   VeilGardeFlywheel   the regime that grows the stack: Area/, Store/, Acquire/, Ingest/,
//                       Candidates/, Battery/, Promote/                          (Swift 5 mode)
//   VeilSeal            the Burgundy Seal: a picture's seal, made from its anchors, the paths
//                       between them and the warp residual of their neighbourhoods, found again in
//                       a crop, a resize, a re-encode or an edit; Anchor/, Path/, Seal/ (the seal,
//                       its store, BurgundySeal), Residual/ (the warp round trip and the fragility
//                       rate), Signature/, Sections/, Match/ (the grid signature, vw1), Mark/ (the
//                       hidden mark), Render/ (PNG, the wax seal and the detection graphic),
//                       Acceptance/              (MLX through Frigate, Veil8's key stream, Swift 5 mode)
//   VeilGardeAudio      the watermark's second carrier: Audio/ (the clip, and the two AVFoundation
//                       doors that read, write and convert it), Spectrogram/ (the two profiles, the
//                       STFT and the 8-bit picture the lens reads unchanged), Watermark/ (a clip
//                       signed and matched through the watermark), Acceptance/
//                                                              (MLX through Frigate, Swift 5 mode)
//   VeilGarde           the umbrella, and the doctor that checks every layer     (Swift 5 mode)
//   VeilGardeCLI        the `veilgarde` executable                               (Swift 5 mode)
//
// Invariants PackageLayeringTests holds: exactly these five products; MLX only through Frigate
// (no mlx-swift URL here, and every MLX or Frigate import sits in a target that lists that
// product); Core imports Foundation and Crypto only; Training never imports Inference or the
// Flywheel; VeilSeal imports Core, Lens, Veil8 and VeilKey and, for its residual, MLX, MLXAccelerate and
// MLXFFT, and neither
// it nor the Lens lists the Frigate umbrella (Inference alone does, for FrigateBoost);
// VeilGardeAudio imports VeilSeal and, for its STFT, MLX, and AVFoundation only in its two
// doors; nothing under Sources/ imports MLXLLM, MLXLMCommon, AppKit (outside the image decoder) or
// UIKit; no type is named like a module; every Swift file opens with a WHAT: header.
//
// Frigate, the family's vendored MLX stack, is taken by path at home: VEILGARDE_FRIGATE_DIR, else
// ../Frigate, else ../../rao/repositories/Frigate (this Mac's layout). Inside another package's
// graph (a SwiftPM checkout, as Veil takes VeilGarde by URL, or VEILGARDE_FRIGATE_URL set) it is
// the family's URL instead, so the graph holds one Frigate: two packages named Frigate, one by path
// and one by URL, are refused. MLX-facing targets use Swift 5 language mode because Frigate's MLX
// types are not Sendable (Braid's choice).

import Foundation
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

/// Frigate's checkout: the one the environment names, else the first sibling layout that holds one.
let frigate: String = {
    let root = URL(fileURLWithPath: Context.packageDirectory)
    var candidates: [String] = []
    if let named = Context.environment["VEILGARDE_FRIGATE_DIR"], !named.isEmpty { candidates.append(named) }
    candidates += ["../Frigate", "../../rao/repositories/Frigate"]
    for candidate in candidates {
        let url = candidate.hasPrefix("/") ? URL(fileURLWithPath: candidate) : root.appendingPathComponent(candidate)
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return candidate }
    }
    return "../Frigate"
}()

/// In another package's graph, Frigate by URL, the one the consumer takes; at home, the checkout by
/// path. SwiftPM reads a dependency's manifest at "/" while it resolves (from the repository, not a
/// folder) and in its checkouts while it builds; VEILGARDE_FRIGATE_URL asks for the URL anywhere.
let frigateByURL: Bool = Context.packageDirectory == "/"
    || Context.packageDirectory.contains("/.build/checkouts/")
    || Context.packageDirectory.contains("/SourcePackages/checkouts/")
    || !(Context.environment["VEILGARDE_FRIGATE_URL"] ?? "").isEmpty
let frigateDependency: Package.Dependency = frigateByURL
    ? .package(url: "https://github.com/rao-studios/Frigate.git", branch: "main")
    : .package(path: frigate)

/// Weights stay out of git. Copied into the Inference resources, the DINOv2 files ship inside the bundle;
/// otherwise WeightLocator finds them in the work area or an override folder.
let optionalWeights: [Resource] = [
    "Resources/dinov2_small.safetensors",
    "Resources/dinov2_small_xsmall.safetensors",
    "Resources/dinov2_small_xxsmall.safetensors",
].filter {
    FileManager.default.fileExists(atPath: Context.packageDirectory + "/Sources/VeilGardeInference/" + $0)
}.map { .copy($0) }

let package = Package(
    name: "VeilGarde",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "VeilGarde", targets: ["VeilGarde"]),
        .library(name: "VeilGardeInference", targets: ["VeilGardeInference"]),
        .library(name: "VeilSeal", targets: ["VeilSeal"]),
        .library(name: "VeilGardeAudio", targets: ["VeilGardeAudio"]),
        .executable(name: "veilgarde", targets: ["VeilGardeCLI"]),
    ],
    dependencies: [
        frigateDependency,
        // Veil8: the keyed, one-way neighbourhood encoding and the key file the seal is keyed with.
        .package(url: "https://github.com/riteshpakala/Veil8.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.2.0"),
    ],
    targets: [
        .target(
            name: "VeilGardeCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .target(
            name: "VeilGardeLens",
            dependencies: [
                "VeilGardeCore",
                .product(name: "MLX", package: "Frigate"),
                .product(name: "MLXNN", package: "Frigate"),
                .product(name: "MLXFFT", package: "Frigate"),
                .product(name: "MLXAccelerate", package: "Frigate"),
            ],
            swiftSettings: v5
        ),
        .target(
            name: "VeilGardeInference",
            dependencies: [
                "VeilGardeLens",
                // FrigateBoost's XGBoostTreeModel, the evaluator the camera head is scored with: the one
                // use of the Frigate umbrella, kept out of the Lens so VeilSeal's graph stays small.
                .product(name: "Frigate", package: "Frigate"),
            ],
            // The shipped bundle: the shipped artifacts, by name, bound by manifest.json. Weights are
            // gitignored and resolved at run time (WeightLocator); copied into this folder they ship
            // inside the bundle.
            resources: [
                .copy("Resources/manifest.json"),
                .copy("Resources/camera.xgb.json"),
                .copy("Resources/stack_combiner.json"),
                .copy("Resources/screenshot_dinov2_v1.10.json"),
                .copy("Resources/art_dinov2_v2.json"),
                .copy("Resources/blur_dinov2_v1.json"),
                .copy("Resources/human_dinov2_v4.json"),
                .copy("Resources/semtile_dinov2_v1.json"),
                .copy("Resources/preview_dinov2_v1.json"),
            ] + optionalWeights,
            swiftSettings: v5
        ),
        .target(
            name: "VeilGardeTraining",
            dependencies: [
                "VeilGardeLens",
                .product(name: "MLX", package: "Frigate"),
                .product(name: "MLXNN", package: "Frigate"),
                .product(name: "FrigateHub", package: "Frigate"),
            ],
            swiftSettings: v5
        ),
        .target(
            name: "VeilGardeFlywheel",
            dependencies: ["VeilGardeTraining", "VeilGardeInference"],
            // The battery's spec and ratchet floors, byte for byte (`flywheel init` copies them into
            // the work area, where the battery reads them); the category router's prompt matrix;
            // the collector jobs that fill each blind spot.
            resources: [
                .copy("Resources/battery_spec.json"),
                .copy("Resources/battery_baseline.json"),
                .copy("Resources/clip_prompts_v1.safetensors"),
                .copy("Resources/acquire_targets_v1.json"),
            ],
            swiftSettings: v5
        ),
        .target(
            name: "VeilSeal",
            dependencies: [
                "VeilGardeLens",
                // The warp residual it reads: Frigate's warp tap tables, bicubic gathers and Gaussian blur;
                // the seams' rFFT for the 19 tile features its residual statistics summarise.
                .product(name: "MLX", package: "Frigate"),
                .product(name: "MLXAccelerate", package: "Frigate"),
                .product(name: "MLXFFT", package: "Frigate"),
                // The seal's key stream and key file.
                .product(name: "Veil8", package: "Veil8"),
                .product(name: "VeilKey", package: "Veil8"),
            ],
            swiftSettings: v5
        ),
        .target(
            name: "VeilGardeAudio",
            dependencies: [
                "VeilSeal",
                // The STFT and its inverse, and the lag between two signals: MLXFFT lives in the MLX module.
                .product(name: "MLX", package: "Frigate"),
            ],
            // The research notes for speech protection, read by people, not built.
            exclude: ["README.md"],
            swiftSettings: v5
        ),
        .target(
            name: "VeilGarde",
            dependencies: ["VeilGardeInference", "VeilGardeTraining", "VeilGardeFlywheel", "VeilSeal", "VeilGardeAudio"],
            swiftSettings: v5
        ),
        .executableTarget(
            name: "VeilGardeCLI",
            dependencies: [
                "VeilGarde",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: v5
        ),
        .testTarget(name: "VeilGardeCoreTests", dependencies: ["VeilGardeCore"], exclude: ["Fixtures"]),
        .testTarget(name: "VeilGardeLensTests", dependencies: ["VeilGardeLens"], exclude: ["Fixtures"], swiftSettings: v5),
        .testTarget(name: "VeilGardeInferenceTests", dependencies: ["VeilGardeInference"], exclude: ["Fixtures"], swiftSettings: v5),
        .testTarget(name: "VeilGardeTrainingTests", dependencies: ["VeilGardeTraining", .product(name: "Frigate", package: "Frigate")], exclude: ["Fixtures"], swiftSettings: v5),
        .testTarget(name: "VeilGardeFlywheelTests", dependencies: ["VeilGardeFlywheel"], swiftSettings: v5),
        .testTarget(name: "VeilSealTests", dependencies: ["VeilSeal"], exclude: ["Fixtures"], swiftSettings: v5),
        .testTarget(name: "VeilGardeAudioTests", dependencies: ["VeilGardeAudio"], exclude: ["Fixtures"], swiftSettings: v5),
        .testTarget(name: "VeilGardeCLITests", dependencies: ["VeilGardeCLI"], swiftSettings: v5),
    ]
)
