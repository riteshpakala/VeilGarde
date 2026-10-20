//
//  MLXGate.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The MLX suites run one at a time and only when asked: VEILGARDE_MLX_TESTS=1 (or
//        FRIGATE_MLX_TESTS=1). Every GPU suite in this target nests under TrainingMLXSuites, which
//        is serialized; run the targets with `swift test --no-parallel` too, so two MLX workloads
//        never overlap.
//

import Foundation
import Testing

let mlxTests: Bool = {
    let env = ProcessInfo.processInfo.environment
    return env["VEILGARDE_MLX_TESTS"] == "1" || env["FRIGATE_MLX_TESTS"] == "1"
}()

@Suite("Training: MLX, one suite at a time", .enabled(if: mlxTests), .serialized)
struct TrainingMLXSuites {}
