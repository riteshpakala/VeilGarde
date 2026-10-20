//
//  LensRuntime.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The MLX runtime controls the layers above need without importing MLX: the default device,
//        a CPU run for A/B checks, the GPU buffer-cache bounds, and releasing cached buffers.
//  PIN:  One MLX workload at a time. The cache bounds mirror Garde's clrConfigureGPUMemory: a
//        sequence of inferences must not grow the Metal working set without bound.
//

import Foundation
import MLX

public enum LensRuntime {
    /// "gpu" or "cpu", as the result JSON's `device` field spells it.
    public static func deviceName(cpu: Bool) -> String { cpu ? "cpu" : "gpu" }

    public static var defaultDeviceDescription: String { "\(Device.defaultDevice())" }

    /// Runs `body` with MLX's default device set to the CPU or the GPU.
    public static func withDevice<T>(cpu: Bool, _ body: () throws -> T) rethrows -> T {
        try Device.withDefaultDevice(cpu ? Device(.cpu) : Device(.gpu), body)
    }

    public static func configureGPUMemory(cacheLimitBytes: Int = 64 * 1024 * 1024, memoryLimitBytes: Int? = nil) {
        Memory.cacheLimit = cacheLimitBytes
        if let m = memoryLimitBytes { Memory.memoryLimit = m }
    }

    public static func releaseMemory() { Memory.clearCache() }
}
