// swift-tools-version: 6.4
// SPDX-License-Identifier: GPL-3.0-only
// VeilGarde — an AI-generated-image detector and a crop-robust watermark, as one package anyone
// can train and run: a fusion head over DINOv2 and the capture signature with a specialist stack
// on it, the trainers and the flywheel that grow them, and a watermark read off a perspective-warp
// residual.
//
// Four products: VeilGarde (everything), VeilGardeInference (the detector alone), VeilWatermark
// (the signature alone) and the `veilgarde` executable. Eight targets, in layers:
//   VeilGardeCore       the domain, Foundation + Crypto only, Swift 6 strict: Support/ (JSON,
//                       hashing, failures, the work area, safetensors, seeded splits), Features/
//                       (capture 9, the screenshot gate, the fusion vector), Boost/ (GBDTModel:
//                       the XGBoost JSON codec and evaluator), Heads/ (linear heads, the stack
//                       combiner), Bundle/ (artifacts, the manifest, SHA-256 binding), Result/
//                       (InferenceResult, the schema-v3 JSON, the verdict law, route batches),
//                       Store/ (the features-only store)
//   VeilGardeLens       the extractors, in the order a pixel travels: Image/, Warp/, Capture/,
//                       Semantic/ (DINOv2, CLIP vision), Scoring/
//                                                          (MLX through Frigate, Swift 5 mode)
//   VeilGardeInference  the detector, in the order a verdict is built: Config/, Fusion/,
//                       Specialists/, Route/ (signals, domain heads, mechanisms, the Detector),
//                       Bundle/ (the shipped artifacts)               (Swift 5 mode, resources)
//   VeilGardeTraining   the trainers: Data/, Extract/, Boost/ (a native GBDT), Linear/, Fusion/,
//                       Heads/, Combiner/, Backbone/ (DINOv2 and CLIP imports), Recipe/, Engine/,
//                       Artifacts/                                               (Swift 5 mode)
//   VeilGardeFlywheel   the regime that grows the fusion head and the specialist stack: Area/,
//                       Store/, Acquire/, Ingest/, Candidates/, Battery/, Promote/ (Swift 5 mode)
//   VeilWatermark       the crop-robust signature on the warp residual: Signature/, Sections/,
//                       Match/, Acceptance/                                      (Swift 5 mode)
//   VeilGarde           the umbrella, and the doctor that checks every layer     (Swift 5 mode)
//   VeilGardeCLI        the `veilgarde` executable                               (Swift 5 mode)
//
// Invariants PackageLayeringTests holds: exactly these four products; MLX only through Frigate
// (no mlx-swift URL here, and every MLX or Frigate import sits in a target that lists that
// product); Core imports Foundation and Crypto only; Training never imports Inference or the
// Flywheel; VeilWatermark imports only Core and Lens; nothing under Sources/ imports MLXLLM,
// MLXLMCommon, AppKit or UIKit; no type is named like a module; every Swift file opens with a
// WHAT: header.
//
// Frigate, the family's vendored MLX stack, is taken by path, as every consumer in the family
// takes it: VEILGARDE_FRIGATE_DIR, else ../Frigate, else ../../rao/repositories/Frigate (this
// Mac's layout). MLX-facing targets use Swift 5 language mode because Frigate's MLX types are not
// Sendable (Braid's choice).

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
        .library(name: "VeilWatermark", targets: ["VeilWatermark"]),
        .executable(name: "veilgarde", targets: ["VeilGardeCLI"]),
    ],
    dependencies: [
        .package(path: frigate),
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
                // FrigateBoost's XGBoostTreeModel, the evaluator the fusion head is scored with.
                .product(name: "Frigate", package: "Frigate"),
            ],
            swiftSettings: v5
        ),
        .target(
            name: "VeilGardeInference",
            dependencies: ["VeilGardeLens"],
            // The shipped bundle: the shipped artifacts, by name, bound by manifest.json. Weights are
            // gitignored and resolved at run time (WeightLocator); copied into this folder they ship
            // inside the bundle.
            resources: [
                .copy("Resources/manifest.json"),
                .copy("Resources/fusion_head.xgb.json"),
                .copy("Resources/stack_combiner_v3.json"),
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
                .copy("Resources/battery_spec_v2.json"),
                .copy("Resources/battery_v2_baseline.json"),
                .copy("Resources/clip_prompts_v1.safetensors"),
                .copy("Resources/acquire_targets_v1.json"),
            ],
            swiftSettings: v5
        ),
        .target(
            name: "VeilWatermark",
            dependencies: ["VeilGardeLens"],
            swiftSettings: v5
        ),
        .target(
            name: "VeilGarde",
            dependencies: ["VeilGardeInference", "VeilGardeTraining", "VeilGardeFlywheel", "VeilWatermark"],
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
        .testTarget(name: "VeilGardeTrainingTests", dependencies: ["VeilGardeTraining"], exclude: ["Fixtures"], swiftSettings: v5),
        .testTarget(name: "VeilGardeFlywheelTests", dependencies: ["VeilGardeFlywheel"], swiftSettings: v5),
        .testTarget(name: "VeilWatermarkTests", dependencies: ["VeilWatermark"], exclude: ["Fixtures"], swiftSettings: v5),
        .testTarget(name: "VeilGardeCLITests", dependencies: ["VeilGardeCLI"], swiftSettings: v5),
    ]
)
