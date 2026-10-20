//
//  Trust.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: How much the public majority deserves to be believed. The camera-sensor vote is "high"
//        only when it is a binary call, on a native route, with a valid and present capture
//        signature, and it agrees with the weighted verdict; everything else is "low". Two
//        abstentions agreeing is not evidence.
//  PIN:  Garde's sensorVoteTrust (campaign_support.sensor_vote_trust, trust law v1) and
//        physicsVoteTrust, unchanged.
//

public enum Trust {
    /// The sensor lane's trust, independent of which lane owns the public majority.
    public static func sensorVote(_ r: InferenceResult, route: String? = nil) -> String {
        guard let sensorPrediction = r.sensorPrediction,
              sensorPrediction == "real" || sensorPrediction == "generated",
              r.weightedPrediction == "real" || r.weightedPrediction == "generated" else {
            return "low"
        }
        let resolvedRoute = route ?? r.routeDiagnostics?.route ?? {
            switch r.majoritySource {
            case .warpSensor: return "camera"
            case .screenshotContent: return "screenshot"
            case .semanticTiles, .none: return ""
            }
        }()
        let nativeRoutes = r.sensorCalibration?.nativeRoutes ?? ["camera"]
        guard nativeRoutes.map({ $0.lowercased() }).contains(resolvedRoute.lowercased()),
              let capture = r.captureSignature, capture.valid, capture.present else {
            return "low"
        }
        return sensorPrediction == r.weightedPrediction ? "high" : "low"
    }

    /// The trust of whichever lane owns the public majority.
    public static func physicsVote(_ r: InferenceResult) -> String {
        if r.majoritySource == .semanticTiles, r.majorityPrediction == "render" { return "taxonomy" }
        guard r.majorityPrediction == "real" || r.majorityPrediction == "generated" else { return "low" }
        switch r.majoritySource {
        case .semanticTiles:
            return r.majorityPrediction == r.weightedPrediction ? "high" : "low"
        case .warpSensor:
            return sensorVote(r)
        case .screenshotContent:
            return r.majorityPrediction == r.weightedPrediction ? "high" : "low"
        case .none:
            return "low"
        }
    }
}
