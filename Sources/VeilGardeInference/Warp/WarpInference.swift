//
//  WarpInference.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The warp lens as a verdict, the camera-sensor score included: the base model's weighted
//        score and its 0.56 label, and the public sensor lane, the fraction of 32-px tiles the
//        sensor model reads above 0.5 projected by the calibration contract into the camera-sensor
//        score and its call. This alone answers "did a real camera make this?" from physics.
//  PIN:  Garde's runInferenceFast, unchanged in behaviour. DUAL-WARP LAW: the sensor model owns
//        only the public sensor surface; the base model owns the weighted score and the fusion.
//        A sensor whose bytes equal the base's reuses the base grid with the historical strict
//        `> 0.5` count; a distinct one is rescored and counts `>= 0.5` (Stage-03's aggregation).
//        A sensor model with an unsupported column count is refused when it was named or a
//        calibration is present. Weights are never renormalized over a partial sensor grid.
//

import CoreGraphics
import Foundation

public enum WarpInference {
    public static func run(cgImage: CGImage, config: InferenceConfig, progress: (Int, Int) -> Void = { _, _ in }) throws -> InferenceResult {
        let clock = PhaseClock(enabled: config.timing)
        let scorer: XGBoostScorer
        let baseModelSHA256: String
        do {
            scorer = try TreeModelCache.shared.scorer(config.modelURL)
            baseModelSHA256 = try ArtifactHashCache.shared.sha256(config.modelURL)
        } catch {
            throw VeilGardeFailure.data("cannot load or hash the base warp model \(config.modelURL.path): \(error)")
        }

        // The dual-warp law.
        let sensorScorer: XGBoostScorer
        let sensorSHA256: String
        let hasDedicatedSensor: Bool
        let needsDedicatedPass: Bool
        if let sensorURL = config.majoritySensorModelURL {
            do {
                sensorSHA256 = try ArtifactHashCache.shared.sha256(sensorURL)
                hasDedicatedSensor = true
                needsDedicatedPass = sensorSHA256 != baseModelSHA256
                sensorScorer = needsDedicatedPass ? try TreeModelCache.shared.scorer(sensorURL) : scorer
            } catch {
                throw VeilGardeFailure.data("cannot load or hash the sensor model \(sensorURL.path): \(error)")
            }
        } else {
            sensorScorer = scorer
            sensorSHA256 = baseModelSHA256
            hasDedicatedSensor = false
            needsDedicatedPass = false
        }
        let sensorVariant: String
        do {
            sensorVariant = try SensorCalibrationContract.variant(featureCount: sensorScorer.featureCount)
        } catch {
            if hasDedicatedSensor || config.sensorCalibrationURL != nil { throw error }
            sensorVariant = "legacy_warp\(sensorScorer.featureCount)"
        }
        let calibration = try SensorCalibrationContract.load(url: config.sensorCalibrationURL, sensorVariant: sensorVariant,
                                                             sensorModelSHA256: sensorSHA256, fallbackBand: config.decision.band)
        clock.note("models and calibration")

        // The capture signature at NATIVE resolution, before any downscale destroys it.
        let capture = CaptureLens.signature(cgImage)
        clock.note("capture signature")

        var warp = config.warp
        warp.keepFeatures = config.featureDumpURL != nil
        let analysis = try WarpLens.analyze(cgImage: cgImage, parameters: warp, scorer: scorer, progress: progress)
        clock.note("warp lens")
        let ps = analysis.patchSize
        if let url = config.featureDumpURL, let features = analysis.features {
            let n = ps / WarpConstants.tileSize
            try features.dumpJSON(patchRows: analysis.patchRows, patchCols: analysis.patchCols, tilesPerPatch: n * n).write(to: url)
        }

        // The sensor lane: the base grid itself when it is the 32-px lane of the same bytes.
        let sensor: SensorSurface
        if needsDedicatedPass || !ScoringGeometry.baseGridIsSensorLane(patchSize: ps) {
            sensor = try SensorSurface.score(cgImage: cgImage, warp: config.warp, scorer: sensorScorer)
            clock.note(needsDedicatedPass ? "dual-warp sensor pass" : "sensor 32-px lane")
        } else {
            sensor = SensorSurface(patchGrid: analysis.patchGrid, rows: analysis.patchRows, cols: analysis.patchCols, patchSize: ps,
                                   imageWidth: analysis.geometry.imageWidth, imageHeight: analysis.geometry.imageHeight)
        }
        let sensorCells = sensor.rows * sensor.cols
        guard sensorCells > 0 else { throw VeilGardeFailure.data("the sensor produced an empty grid") }
        let generated = sensor.patchGrid.flatMap { $0 }.filter { needsDedicatedPass ? $0 >= 0.5 : $0 > 0.5 }.count
        let sensorRaw = Float(generated) / Float(sensorCells)
        let sensorProbability = calibration.calibratedProbability(sensorRaw)
        let sensorPrediction = calibration.prediction(for: sensorProbability)

        var patches = [PatchInfo]()
        patches.reserveCapacity(sensorCells)
        for I in 0..<sensor.rows {
            for J in 0..<sensor.cols {
                let x = J * sensor.patchSize, y = I * sensor.patchSize
                patches.append(PatchInfo(
                    row: I, col: J, pGenerated: sensor.patchGrid[I][J],
                    weight: ScoringGeometry.baseWeightContribution(weightMap: analysis.weightMap, x: x, y: y, basePatchSize: ps, sensorPatchSize: sensor.patchSize),
                    x: x, y: y, width: min(sensor.patchSize, sensor.imageWidth - x), height: min(sensor.patchSize, sensor.imageHeight - y)))
            }
        }
        return InferenceResult(
            scorer: "xgboost",
            majorityPrediction: sensorPrediction, majorityScore: sensorProbability,
            weightedPrediction: config.decision.label(analysis.weightedScore), weightedScore: analysis.weightedScore,
            patches: patches, gridRows: sensor.rows, gridCols: sensor.cols, patchSize: sensor.patchSize,
            imageWidth: sensor.imageWidth, imageHeight: sensor.imageHeight,
            decisionThreshold: config.decision.threshold, uncertainBand: config.decision.band,
            nativeScore: analysis.nativeScore, nativeDisagreement: analysis.nativeDisagreement,
            captureSignature: capture, sharpness: analysis.sharpness,
            sensorRawProbability: sensorRaw, sensorProbability: sensorProbability, sensorPrediction: sensorPrediction,
            sensorCalibration: calibration, baseWarpModelSHA256: baseModelSHA256, sensorWarpModelSHA256: sensorSHA256)
    }
}

/// Per-phase wall times on stderr when timing is on.
final class PhaseClock {
    private let enabled: Bool
    private var last = DispatchTime.now()

    init(enabled: Bool) { self.enabled = enabled }

    func note(_ label: String) {
        guard enabled else { return }
        let now = DispatchTime.now()
        let ms = Double(now.uptimeNanoseconds - last.uptimeNanoseconds) / 1e6
        FileHandle.standardError.write(Data("[veilgarde] \(label): \(String(format: "%.1f", ms)) ms\n".utf8))
        last = now
    }
}
