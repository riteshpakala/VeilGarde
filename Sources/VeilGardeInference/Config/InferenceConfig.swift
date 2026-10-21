//
//  InferenceConfig.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: How one detection runs, grouped by what each setting governs: the models (the frozen
//        base warp model, the public sensor model and its calibration), the warp lens
//        (patch size, the 512 cap, quantized warps, the weight map and hotspot rule, the native
//        check), the weighted verdict's operating point, the semantic backbone, the camera
//        domain's base expert, and the router's mechanisms and campaign switches.
//  PIN:  Every default is Garde's InferenceConfig default, and the model URLs default to the
//        shipped bundle, the sensor pair included: a nil sensor default would silently fall back
//        to the identity calibration, the one change that passes tests and moves verdicts. The base
//        expert defaults to the fusion head; the warp lens alone is a measurement mode (the
//        2026-10-20 detector studies), and promote and rollback never set it.
//

import Foundation

/// The router's mechanisms and the same-binary campaign switches.
public struct RouterMechanisms: Sendable, Equatable {
    /// Production `.control`; diagnostic and removed profiles are ablations.
    public var semanticResponsibility: SemanticResponsibility = .control
    /// Production `.warpSensor`; `.legacySemantic` replays the pre-Stage-1 surface.
    public var resultSurface: ResultSurface = .warpSensor
    /// `conflict ∧ cgi ≥ 0.5 → "render"`: suspended since 2026-07-19 (the render class proved
    /// unreliable); kept behind this flag for a re-work on provenance grounds.
    public var renderTaxonomy = false
    /// v3.2 zoom escalation: disabled since 2026-07-19 (its flagship flip was adjudicated a false
    /// positive); kept for recalibration against confirmed true positives only.
    public var zoomEscalation = false
    /// v0 x-domain trust gate (meme-family centroids): surfacing only, off by default.
    public var xDomainGate = false

    public init() {}
}

/// The camera domain's base expert: what the specialist stack compounds onto.
public enum BaseExpert: String, Sendable, Codable, CaseIterable {
    /// The warp lens and the fusion head over DINOv2, capture and sharpness: the detector.
    case fusion
    /// The warp lens alone, its weighted score at the config's decision rule: a measurement mode.
    case warp
}

public struct InferenceConfig: Sendable {
    /// The artifacts this detection reads (the shipped bundle unless told otherwise).
    public var bundle: DetectorBundle
    /// The frozen base warp model: it feeds the weighted score and the fusion.
    public var modelURL: URL
    /// The public sensor model; when its bytes equal the base's, the base grid is reused.
    public var majoritySensorModelURL: URL?
    /// The sensor calibration contract; nil means the identity fallback at T = 0.5.
    public var sensorCalibrationURL: URL?
    public var warp: WarpParameters
    /// The warp-only weighted verdict's operating point (0.56 ± 0.04).
    public var decision: DecisionRule
    public var dinoVariant: DinoVariant
    /// The camera domain's base expert (the fusion head unless a study asks for the warp lens alone).
    public var baseExpert: BaseExpert
    public var mechanisms: RouterMechanisms
    /// Write the tile feature matrix here (Garde's --dump-features format).
    public var featureDumpURL: URL?
    /// Per-phase timings on stderr.
    public var timing: Bool
    /// The frame-interior mechanism's recursion guard; never set by callers.
    public var skipFrameCheck: Bool

    /// The models default to the bundle's: its warp tile model, its sensor model and calibration.
    public init(bundle: DetectorBundle = .shipped,
                warp: WarpParameters = WarpParameters(), decision: DecisionRule = .warpWeighted, dinoVariant: DinoVariant = .small,
                baseExpert: BaseExpert = .fusion, mechanisms: RouterMechanisms = RouterMechanisms(), featureDumpURL: URL? = nil, timing: Bool = false) {
        self.bundle = bundle
        self.modelURL = bundle.url(.warpTile) ?? ShippedBundle.url(.warpTile)
        self.majoritySensorModelURL = bundle.url(.warpMajoritySensor)
        self.sensorCalibrationURL = bundle.url(.sensorCalibration)
        self.warp = warp
        self.decision = decision
        self.dinoVariant = dinoVariant
        self.baseExpert = baseExpert
        self.mechanisms = mechanisms
        self.featureDumpURL = featureDumpURL
        self.timing = timing
        self.skipFrameCheck = false
    }

    /// Reads every model from `bundle` instead: its warp tile model, its sensor model and calibration.
    public mutating func rebind(to bundle: DetectorBundle) {
        self.bundle = bundle
        modelURL = bundle.url(.warpTile) ?? ShippedBundle.url(.warpTile)
        majoritySensorModelURL = bundle.url(.warpMajoritySensor)
        sensorCalibrationURL = bundle.url(.sensorCalibration)
    }

    /// The shipped defaults.
    public static var shipped: InferenceConfig { InferenceConfig() }
}
