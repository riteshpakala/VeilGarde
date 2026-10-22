// swift-tools-version: 6.4
// SPDX-License-Identifier: GPL-3.0-only
// WHAT: VeilGarde's examples, a package of its own: one program, read top to bottom, that runs
//       VeilGarde's two lanes on this Mac (the shared signals, the camera head, every member of
//       the stack and the revisions), its training regime, the flywheel and the watermark.
//       Examples/run.sh builds it (release) and runs it. Until 2026-10-21 it was the playground.
// PIN:  VeilGarde by path, Swift 5 mode like VeilGarde's MLX targets. A package rather than an
//       Xcode playground: MLX finds mlx.metallib only beside the running binary, and training
//       wants Release (Braid's playground, for the same reasons).
import PackageDescription

let package = Package(
    name: "VeilGardeExamples",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "VeilGardeExamples",
            dependencies: [.product(name: "VeilGarde", package: "VeilGarde")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
