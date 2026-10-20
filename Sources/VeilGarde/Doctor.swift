//
//  Doctor.swift
//  VeilGarde
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The checks `veilgarde doctor` prints before anything else: MLX's Metal library beside the
//        binary, the work area and its free space, the shipped bundle re-hashed against its
//        manifest, and each weight file found and matching its expected hash. Each layer adds its
//        own check here, so one command says what is missing and how to fix it.
//  OUT:  One DoctorCheck per line; the command exits 1 when any fails.
//

import Foundation

public struct DoctorCheck: Sendable, Equatable {
    public var name: String
    public var ok: Bool
    public var detail: String

    public init(_ name: String, ok: Bool, _ detail: String) {
        self.name = name
        self.ok = ok
        self.detail = detail
    }

    public var line: String {
        let padded = name.padding(toLength: max(name.count, 14), withPad: " ", startingAt: 0)
        return "\(ok ? "ok  " : "FAIL")  \(padded)  \(detail)"
    }
}

public enum Doctor {
    /// The minimum free space a work area should keep: the store, a tile cache and the staged
    /// candidates fit in far less, but the T9 is shared.
    public static let minimumFreeBytes: Int64 = 5 << 30

    public static func run(area: Result<WorkArea, Error>, executable: URL? = Bundle.main.executableURL) -> [DoctorCheck] {
        var checks: [DoctorCheck] = [metalLibrary(executable: executable)]
        switch area {
        case .failure(let error):
            checks.append(DoctorCheck("work area", ok: false, "\(error)"))
        case .success(let area):
            checks.append(workArea(area))
            if let free = area.freeBytes() {
                checks.append(DoctorCheck("free space", ok: free >= minimumFreeBytes,
                                          "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free on the work area's volume"))
            }
        }
        checks.append(shippedBundle())
        ShippedBundle.registerWeightFolders(workArea: try? area.get())
        checks.append(contentsOf: weights())
        return checks
    }

    static func shippedBundle() -> DoctorCheck {
        do {
            let bundle = try ShippedBundle.verified()
            return DoctorCheck("bundle", ok: true, "\(bundle.manifest.artifacts.count) artifacts verified (\(ShippedBundle.directory.lastPathComponent))")
        } catch {
            return DoctorCheck("bundle", ok: false, "\(error)")
        }
    }

    /// Each weight the shipped manifest expects: found, and the hash it was ported with.
    static func weights() -> [DoctorCheck] {
        ShippedBundle.manifest.weights.map { expected in
            guard let url = WeightLocator.shared.url(named: expected.file) else {
                let how = expected.file.hasPrefix("noiseprint")
                    ? "it ships in Sources/VeilGardeInference/Resources: restore it from git, or train one (`veilgarde train noiseprint`)"
                    : "`veilgarde weights import-dinov2` builds it from Hugging Face's checkpoint; fusion, the heads and routing need it"
                return DoctorCheck("weights", ok: false, "\(expected.file) not found in the work area's weights/: \(how)")
            }
            guard let sha = try? ArtifactHashCache.shared.sha256(url) else { return DoctorCheck("weights", ok: false, "cannot read \(url.path)") }
            return DoctorCheck("weights", ok: sha == expected.sha256, sha == expected.sha256 ? url.path : "\(url.path) hashes \(sha.prefix(12)), expected \(expected.sha256.prefix(12))")
        }
    }

    static func metalLibrary(executable: URL?) -> DoctorCheck {
        guard let directory = executable?.deletingLastPathComponent() else {
            return DoctorCheck("metal", ok: false, "cannot locate this binary's folder")
        }
        let library = directory.appendingPathComponent("mlx.metallib")
        if FileManager.default.fileExists(atPath: library.path) {
            return DoctorCheck("metal", ok: true, library.path)
        }
        return DoctorCheck("metal", ok: false, "no mlx.metallib beside \(directory.path)\n        run scripts/cli.sh (it installs one) or ./build-metallib.sh")
    }

    static func workArea(_ area: WorkArea) -> DoctorCheck {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: area.root.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { return DoctorCheck("work area", ok: false, "\(area.root.path) is a file") }
            return DoctorCheck("work area", ok: manager.isWritableFile(atPath: area.root.path),
                               manager.isWritableFile(atPath: area.root.path) ? area.root.path : "\(area.root.path) is not writable")
        }
        let parent = area.root.deletingLastPathComponent()
        return DoctorCheck("work area", ok: manager.isWritableFile(atPath: parent.path),
                           "\(area.root.path) (created on first use)")
    }
}
