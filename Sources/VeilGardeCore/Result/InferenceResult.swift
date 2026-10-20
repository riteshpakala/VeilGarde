//
//  InferenceResult.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Everything the detector says about one image. Two numbers carry the verdict:
//        `majority` is the warp lens's own vote (on a camera route, the calibrated camera-sensor
//        score, the physics anchor that is never overwritten), and `weighted` is the compounded
//        score the label is read from (warp → fusion → specialists → mechanisms). Around them: the
//        per-tile sensor map, the sensor lane's raw and calibrated values, the capture signature,
//        the specialists that weighed in, the semantic tiles, and the route trace.
//  PIN:  Garde's InferenceResult, field for field: ResultJSON writes these into the schema-v2
//        JSON the battery and the Garde-equivalence check read. When an older caller sets only a
//        warp-sourced majority, the sensor fields default to it.
//

public struct InferenceResult: Sendable {
    /// Which scoring produced this result ("xgboost", "screenshot", …).
    public let scorer: String
    /// "generated" | "real" | "inconclusive".
    public let majorityPrediction: String
    public let majorityScore: Float
    public let majoritySource: ResultSource
    /// The raw image-level fraction of sensor tiles above 0.5.
    public let sensorRawProbability: Float?
    /// Its calibrated projection (identity or Platt).
    public let sensorProbability: Float?
    public let sensorPrediction: String?
    public let sensorCalibration: SensorCalibrationContract?
    /// The frozen base warp model feeding the weighted score and the fusion.
    public let baseWarpModelSHA256: String?
    /// The public sensor model (equal to the base hash when no dedicated sensor ships).
    public let sensorWarpModelSHA256: String?
    public let weightedPrediction: String
    public let weightedScore: Float
    public let patches: [PatchInfo]
    public let gridRows: Int
    public let gridCols: Int
    public let patchSize: Int
    public let imageWidth: Int
    public let imageHeight: Int
    /// The weighted verdict's operating point, echoed for display and JSON.
    public let decisionThreshold: Float
    public let uncertainBand: Float
    /// The native-resolution centre-crop check: its weighted score and its disagreement.
    public let nativeScore: Float?
    public let nativeDisagreement: Float?
    public let captureSignature: CaptureSignature?
    /// The flat-UI screenshot gate fired inside the camera base.
    public let isScreenshot: Bool
    public let sharpness: SharpnessFeatures?
    /// The specialists that contributed (base expert, priors, mechanisms), each with its own call.
    public let specialists: [SpecialistContribution]?
    /// Per-patch-token P(generated) on DINOv2's 16×16 grid: diagnostic, never the public majority.
    public let semanticTiles: [[Float]]?
    public let tileMapSource: ResultSource
    public let routeDiagnostics: RouteDiagnostics?

    /// The share of the frozen base verdict's weight the visible sensor cells carry. Not
    /// renormalized when a sensor grid drops incomplete edge tiles.
    public var visibleBaseWeightShare: Float { patches.reduce(0) { $0 + $1.weight } }

    public init(scorer: String = "xgboost", majorityPrediction: String, majorityScore: Float, weightedPrediction: String, weightedScore: Float,
                patches: [PatchInfo], gridRows: Int, gridCols: Int, patchSize: Int, imageWidth: Int, imageHeight: Int,
                decisionThreshold: Float, uncertainBand: Float, nativeScore: Float?, nativeDisagreement: Float?,
                captureSignature: CaptureSignature? = nil, isScreenshot: Bool = false, sharpness: SharpnessFeatures? = nil,
                specialists: [SpecialistContribution]? = nil, semanticTiles: [[Float]]? = nil,
                majoritySource: ResultSource = .warpSensor, tileMapSource: ResultSource = .warpSensor,
                sensorRawProbability: Float? = nil, sensorProbability: Float? = nil, sensorPrediction: String? = nil,
                sensorCalibration: SensorCalibrationContract? = nil, baseWarpModelSHA256: String? = nil,
                sensorWarpModelSHA256: String? = nil, routeDiagnostics: RouteDiagnostics? = nil) {
        self.scorer = scorer
        self.majorityPrediction = majorityPrediction
        self.majorityScore = majorityScore
        self.majoritySource = majoritySource
        self.sensorRawProbability = sensorRawProbability ?? (majoritySource == .warpSensor ? majorityScore : nil)
        self.sensorProbability = sensorProbability ?? (majoritySource == .warpSensor ? majorityScore : nil)
        self.sensorPrediction = sensorPrediction ?? (majoritySource == .warpSensor ? majorityPrediction : nil)
        self.sensorCalibration = sensorCalibration
        self.baseWarpModelSHA256 = baseWarpModelSHA256
        self.sensorWarpModelSHA256 = sensorWarpModelSHA256
        self.weightedPrediction = weightedPrediction
        self.weightedScore = weightedScore
        self.patches = patches
        self.gridRows = gridRows
        self.gridCols = gridCols
        self.patchSize = patchSize
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.decisionThreshold = decisionThreshold
        self.uncertainBand = uncertainBand
        self.nativeScore = nativeScore
        self.nativeDisagreement = nativeDisagreement
        self.captureSignature = captureSignature
        self.isScreenshot = isScreenshot
        self.sharpness = sharpness
        self.specialists = specialists
        self.semanticTiles = semanticTiles
        self.tileMapSource = tileMapSource
        self.routeDiagnostics = routeDiagnostics
    }
}
