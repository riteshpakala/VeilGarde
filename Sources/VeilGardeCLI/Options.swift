//
//  Options.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The options every command shares: the work area (--work-area, else VEILGARDE_WORK_AREA,
//        else refused), the failure mapping to sysexits so scripts can branch, and the stderr note
//        every progress line goes through.
//

import ArgumentParser
import CoreGraphics
import Foundation
import VeilGarde

struct WorkAreaOptions: ParsableArguments {
    @Option(name: .customLong("work-area"), help: "Where VeilGarde's data lives (default: VEILGARDE_WORK_AREA).")
    var workAreaPath: String?

    func resolve() throws -> WorkArea {
        if let workAreaPath { return WorkArea(root: URL(fileURLWithPath: (workAreaPath as NSString).expandingTildeInPath, isDirectory: true)) }
        guard let area = WorkArea.resolve() else {
            throw VeilGardeFailure.configuration("no work area", hint: "set VEILGARDE_WORK_AREA or pass --work-area: VeilGarde writes no data it was not told where to put")
        }
        return area
    }
}

/// Runs a command body, printing a VeilGardeFailure and exiting with its code; other errors are internal.
func guarded(_ body: () throws -> Void) {
    do {
        try body()
    } catch let failure as VeilGardeFailure {
        FileHandle.standardError.write(Data("veilgarde: \(failure.description)\n".utf8))
        exit(failure.code.rawValue)
    } catch let exit as ArgumentParser.ExitCode {
        Foundation.exit(exit.rawValue)
    } catch {
        FileHandle.standardError.write(Data("veilgarde: \(error)\n".utf8))
        exit(FailureCode.internalError.rawValue)
    }
}

/// The async form of `guarded`.
func guardedAsync(_ body: () async throws -> Void) async {
    do {
        try await body()
    } catch let failure as VeilGardeFailure {
        FileHandle.standardError.write(Data("veilgarde: \(failure.description)\n".utf8))
        exit(failure.code.rawValue)
    } catch let exit as ArgumentParser.ExitCode {
        Foundation.exit(exit.rawValue)
    } catch {
        FileHandle.standardError.write(Data("veilgarde: \(error)\n".utf8))
        exit(FailureCode.internalError.rawValue)
    }
}

/// A progress line, to stderr.
func note(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

/// Reads an image the way the detector sees it (EXIF orientation applied).
func loadImage(_ path: String) throws -> CGImage {
    try ImageDecoding.cgImage(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
}

/// The images an argument names: a text file of paths (one per line, `#` comments), a folder
/// (searched recursively, sorted by path, exFAT sidecars skipped), or one image.
func imageInputs(_ input: String) throws -> [URL] {
    let url = datasetURL(input)
    if url.pathExtension == "txt" {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }.map(datasetURL)
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw VeilGardeFailure.missing("no image or folder at \(url.path)") }
    guard isDirectory.boolValue else { return [url] }
    var out: [URL] = []
    let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    while let next = walker?.nextObject() as? URL {
        let name = next.lastPathComponent
        guard !name.hasPrefix("._"), ShardExtractor.imageExtensions.contains(next.pathExtension.lowercased()) else { continue }
        out.append(next)
    }
    return out.sorted { $0.path < $1.path }
}

/// Writes JSON to stdout with a trailing newline (`--json -`), or to a file.
func emitJSON(_ data: Data, to destination: String) throws {
    if destination == "-" {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        try data.write(to: URL(fileURLWithPath: (destination as NSString).expandingTildeInPath))
    }
}

/// Wall seconds of `body`.
func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let t0 = DispatchTime.now()
    let value = try body()
    return (value, Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9)
}

/// The detector's flags, shared by `route`, `batch` and `research census`.
struct RouteOptions: ParsableArguments {
    @Option(name: .customLong("semantic-profile"), help: "control, semantic_diagnostic_only or semantic_removed.")
    var semanticProfile: String = SemanticResponsibility.control.rawValue
    @Option(help: "DINOv2 weights: small (F32), xsmall (F16) or xxsmall (int8).")
    var dino: String = DinoVariant.small.rawValue
    @Option(help: "A bundle directory to detect with instead of the shipped one (the flywheel's live/ or a candidate).")
    var bundle: String?
    @Option(name: .customLong("weights-dir"), help: "A folder searched first for the DINOv2 and CLIP weights.")
    var weightsDir: String?

    func config() throws -> InferenceConfig {
        ShippedBundle.registerWeightFolders()
        if let weightsDir { WeightLocator.shared.setOverride(URL(fileURLWithPath: (weightsDir as NSString).expandingTildeInPath, isDirectory: true)) }
        let detectorBundle = try bundle.map { try DetectorBundle.load(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)) } ?? .shipped
        guard let profile = SemanticResponsibility(rawValue: semanticProfile) else {
            throw VeilGardeFailure.usage("--semantic-profile must be control, semantic_diagnostic_only or semantic_removed, not \(semanticProfile)")
        }
        guard let variant = DinoVariant(rawValue: dino) else { throw VeilGardeFailure.usage("--dino must be small, xsmall or xxsmall, not \(dino)") }
        return InferenceConfig(bundle: detectorBundle, dinoVariant: variant, semanticResponsibility: profile)
    }
}

func parseHint(_ raw: String?) throws -> DetectionDomain? {
    guard let raw else { return nil }
    guard let hint = DetectionDomain(rawValue: raw) else { throw VeilGardeFailure.usage("--hint must be camera or screenshot, not \(raw)") }
    return hint
}
