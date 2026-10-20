//
//  WeightLocator.swift
//  VeilGardeLens
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Where the neural weights are found. Only the noiseprint's ships in git, in the shipped
//        bundle's resources, so each is looked up by file name: an override folder a host sets, then
//        VEILGARDE_WEIGHTS, then the folders registered at start-up (the work area's weights/ and the
//        shipped bundle's resources).
//  PIN:  Garde's weight-override contract, generalized to an ordered search. The first folder
//        that holds the file wins; nothing is downloaded here (`veilgarde weights` does that).
//

import Foundation

public enum WeightFile: String, CaseIterable, Sendable {
    case dinov2Small = "dinov2_small.safetensors"
    case dinov2XSmall = "dinov2_small_xsmall.safetensors"
    case dinov2XXSmall = "dinov2_small_xxsmall.safetensors"
    case noiseprint = "noiseprint_v1.safetensors"
    case clipVision = "clip_vit_b32_vision.safetensors"

    public var role: ArtifactRole {
        switch self {
        case .dinov2Small: return .dinov2Small
        case .dinov2XSmall: return .dinov2XSmall
        case .dinov2XXSmall: return .dinov2XXSmall
        case .noiseprint: return .noiseprint
        case .clipVision: return .clipVision
        }
    }
}

public final class WeightLocator: @unchecked Sendable {
    public static let shared = WeightLocator()
    public static let environmentKey = "VEILGARDE_WEIGHTS"

    private let lock = NSLock()
    private var override: URL?
    private var registered: [URL] = []

    /// A folder searched before every other (a host app's own copy, `--weights-dir`).
    public func setOverride(_ directory: URL?) {
        lock.lock(); override = directory; lock.unlock()
    }

    /// A folder searched after the override and the environment, once.
    public func register(_ directory: URL) {
        lock.lock()
        if !registered.contains(directory.standardizedFileURL) { registered.append(directory.standardizedFileURL) }
        lock.unlock()
    }

    /// Every folder searched, in order.
    public func searchPath() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        var path: [URL] = []
        if let override { path.append(override) }
        if let env = ProcessInfo.processInfo.environment[Self.environmentKey], !env.isEmpty {
            path.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true))
        }
        return path + registered
    }

    public func url(_ file: WeightFile) -> URL? { url(named: file.rawValue) }

    public func url(named name: String) -> URL? {
        for directory in searchPath() {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The weight file, or a failure naming where it was looked for.
    public func require(_ file: WeightFile) throws -> URL {
        if let url = url(file) { return url }
        throw VeilGardeFailure.missing("no \(file.rawValue) in \(searchPath().map(\.path).joined(separator: ", "))",
                                       hint: "put the weights in the work area's weights/ (`veilgarde weights import-dinov2` builds DINOv2's), or pass --weights-dir")
    }
}
