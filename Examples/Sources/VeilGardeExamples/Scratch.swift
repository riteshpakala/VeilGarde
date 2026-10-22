//
//  Scratch.swift
//  VeilGardeExamples
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The examples' own work area (Examples/.work, gitignored) and MLX's Metal library
//        beside whichever binary runs: run.sh installs it, and a run from Xcode copies the one
//        Frigate's build-metallib.sh staged.
//

import Foundation
import VeilGarde

enum Scratch {
    static let work = Images.repoRoot.appendingPathComponent("Examples/.work", isDirectory: true)

    static var workArea: WorkArea { WorkArea(root: work) }

    /// Copies a staged mlx.metallib beside this binary when none is there; returns its source.
    static func installMetalLibrary() throws -> String? {
        guard let binary = Bundle.main.executableURL else { return nil }
        let target = binary.deletingLastPathComponent().appendingPathComponent("mlx.metallib")
        if FileManager.default.fileExists(atPath: target.path) { return nil }
        let candidates = [
            Images.repoRoot.appendingPathComponent(".build/out/Products/Release/mlx.metallib"),
            Images.repoRoot.appendingPathComponent(".build/out/Products/Debug/mlx.metallib"),
        ]
        guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw VeilGardeFailure.missing("no mlx.metallib beside \(binary.path)", hint: "run Examples/run.sh, which installs it")
        }
        try FileManager.default.copyItem(at: source, to: target)
        return source.path
    }
}
