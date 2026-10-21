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

/// The flags every detection command shares, mapped onto an InferenceConfig.
struct DetectionOptions: ParsableArguments {
    @Option(help: "Presentation patch size in pixels, a multiple of 32 (the sensor lane is always the 32-px grid).")
    var patch: Int = 32
    @Option(help: "A base warp model to score with instead of the shipped one (XGBoost JSON).")
    var model: String?
    @Flag(help: "Run MLX on the CPU (an A/B check that the hot path normally runs on the GPU).")
    var cpu = false
    @Flag(name: .customLong("exact-warp"), help: "Exact double warp coordinates instead of cv2's 1/32-pixel quantization (debugging only).")
    var exactWarp = false
    @Option(help: "Hotspot blend: off, asymmetric or symmetric.")
    var hotspot: String = HotspotMode.symmetric.rawValue
    @Option(help: "The weighted verdict's threshold (default 0.56).")
    var threshold: Float?
    @Option(help: "The weighted verdict's inconclusive band (default 0.04).")
    var band: Float?
    @Flag(name: .customLong("native-check"), help: "Also score the native-resolution centre crop and report the disagreement.")
    var nativeCheck = false
    @Flag(name: .customLong("full-res"), help: "Analyse at native resolution (no 512 cap; out of the model's training distribution).")
    var fullRes = false
    @Flag(help: "Per-phase timings on stderr.")
    var timing = false
    @Option(name: .customLong("weights-dir"), help: "A folder searched first for the DINOv2, noiseprint and CLIP weights.")
    var weightsDir: String?

    func config() throws -> InferenceConfig {
        ShippedBundle.registerWeightFolders()
        if let weightsDir { WeightLocator.shared.setOverride(URL(fileURLWithPath: (weightsDir as NSString).expandingTildeInPath, isDirectory: true)) }
        guard patch > 0, patch % 32 == 0 else { throw VeilGardeFailure.usage("--patch must be a positive multiple of 32, not \(patch)") }
        guard let mode = HotspotMode(rawValue: hotspot) else { throw VeilGardeFailure.usage("--hotspot must be off, asymmetric or symmetric, not \(hotspot)") }
        var config = InferenceConfig()
        if let model { config.modelURL = URL(fileURLWithPath: (model as NSString).expandingTildeInPath) }
        config.warp.patchSize = patch
        config.warp.quantizeLikeCV2 = !exactWarp
        config.warp.hotspot.mode = mode
        config.warp.nativeCheck = nativeCheck
        config.warp.fullResolution = fullRes
        if let threshold { config.decision.threshold = threshold }
        if let band { config.decision.band = band }
        config.timing = timing
        return config
    }

    /// The same, reading every model from `bundle`; a --model override still wins for the base warp model.
    func config(bundle: DetectorBundle) throws -> InferenceConfig {
        var config = try config()
        let modelOverride = model.map { _ in config.modelURL }
        config.rebind(to: bundle)
        if let modelOverride { config.modelURL = modelOverride }
        return config
    }
}

/// `--base`: the camera domain's base expert, the fusion head unless a study asks for the warp lens alone.
struct BaseExpertOptions: ParsableArguments {
    @Option(name: .customLong("base"), help: "The camera base expert: fusion (the detector) or warp (the warp lens alone at 0.56 ± 0.04, a measurement mode).")
    var base: String = BaseExpert.fusion.rawValue

    func resolve() throws -> BaseExpert {
        guard let expert = BaseExpert(rawValue: base) else { throw VeilGardeFailure.usage("--base is fusion or warp, not \(base)") }
        return expert
    }
}

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

/// The router's flags, shared by `route` and `batch`.
struct RouteOptions: ParsableArguments {
    @Option(name: .customLong("semantic-profile"), help: "control, semantic_diagnostic_only or semantic_removed.")
    var semanticProfile: String = SemanticResponsibility.control.rawValue
    @Option(name: .customLong("result-surface"), help: "warp-sensor or legacy-semantic.")
    var resultSurface: String = ResultSurface.warpSensor.rawValue
    @Option(name: .customLong("majority-model"), help: "A candidate sensor model (needs --majority-calibration).")
    var majorityModel: String?
    @Option(name: .customLong("majority-calibration"), help: "Its calibration contract (needs --majority-model).")
    var majorityCalibration: String?
    @Flag(name: .customLong("render-taxonomy"), help: "Re-enable the suspended render taxonomy (campaign use).")
    var renderTaxonomy = false
    @Flag(name: .customLong("zoom-escalation"), help: "Re-enable the disabled zoom escalation (campaign use).")
    var zoomEscalation = false
    @Flag(name: .customLong("x-domain-gate"), help: "Enable the v0 x-domain trust gate (surfacing only).")
    var xDomainGate = false
    @Option(help: "DINOv2 weights: small (F32), xsmall (F16) or xxsmall (int8).")
    var dino: String = DinoVariant.small.rawValue
    @Option(help: "A bundle directory to detect with instead of the shipped one (the flywheel's live/ or a candidate).")
    var bundle: String?
    @Option(name: .customLong("weights-dir"), help: "A folder searched first for the DINOv2, noiseprint and CLIP weights.")
    var weightsDir: String?

    func config() throws -> InferenceConfig {
        ShippedBundle.registerWeightFolders()
        if let weightsDir { WeightLocator.shared.setOverride(URL(fileURLWithPath: (weightsDir as NSString).expandingTildeInPath, isDirectory: true)) }
        let detectorBundle = try bundle.map { try DetectorBundle.load(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)) } ?? .shipped
        var config = InferenceConfig(bundle: detectorBundle)
        guard let profile = SemanticResponsibility(rawValue: semanticProfile) else {
            throw VeilGardeFailure.usage("--semantic-profile must be control, semantic_diagnostic_only or semantic_removed, not \(semanticProfile)")
        }
        guard let surface = ResultSurface(rawValue: resultSurface) else {
            throw VeilGardeFailure.usage("--result-surface must be warp-sensor or legacy-semantic, not \(resultSurface)")
        }
        guard let variant = DinoVariant(rawValue: dino) else { throw VeilGardeFailure.usage("--dino must be small, xsmall or xxsmall, not \(dino)") }
        config.mechanisms.semanticResponsibility = profile
        config.mechanisms.resultSurface = surface
        config.mechanisms.renderTaxonomy = renderTaxonomy
        config.mechanisms.zoomEscalation = zoomEscalation
        config.mechanisms.xDomainGate = xDomainGate
        config.dinoVariant = variant
        // A calibration binds to its model's SHA-256: the two are given together or not at all.
        switch (majorityModel, majorityCalibration) {
        case let (model?, calibration?):
            config.majoritySensorModelURL = URL(fileURLWithPath: (model as NSString).expandingTildeInPath)
            config.sensorCalibrationURL = URL(fileURLWithPath: (calibration as NSString).expandingTildeInPath)
        case (nil, nil):
            break
        case (_?, nil):
            throw VeilGardeFailure.usage("--majority-model needs a paired --majority-calibration (a model without its contract cannot be trusted)")
        case (nil, _?):
            throw VeilGardeFailure.usage("--majority-calibration needs a paired --majority-model (a contract binds to its model's SHA-256)")
        }
        return config
    }
}

func parseHint(_ raw: String?) throws -> DetectionDomain? {
    guard let raw else { return nil }
    guard let hint = DetectionDomain(rawValue: raw) else { throw VeilGardeFailure.usage("--hint must be camera or screenshot, not \(raw)") }
    return hint
}
