// swift-tools-version: 6.4
// SPDX-License-Identifier: GPL-3.0-only
// WHAT: The VeilGarde playground, a package of its own: one program, read top to bottom, that runs
//       VeilGarde's inference regime on this Mac (the warp lens and its camera-sensor score, capture,
//       fusion, the specialist stack) and, as the layers land, its training regime, the flywheel
//       and the watermark. Playground/run.sh builds it (release) and runs it.
// PIN:  VeilGarde by path, Swift 5 mode like VeilGarde's MLX targets. A package rather than an
//       Xcode playground: MLX finds mlx.metallib only beside the running binary, and training
//       wants Release (Braid's playground, for the same reasons).
import PackageDescription

let package = Package(
    name: "VeilGardePlayground",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "VeilGardePlayground",
            dependencies: [.product(name: "VeilGarde", package: "VeilGarde")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
