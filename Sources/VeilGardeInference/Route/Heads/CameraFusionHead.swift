//
//  CameraFusionHead.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The camera domain's base expert: the warp lens and the fusion head, the spine the
//        specialist stack compounds onto. Registered by default and the fallback for any domain
//        without its own head. A study can ask for the warp lens alone in the fusion head's place
//        (InferenceConfig.baseExpert), to measure what the fusion head is worth in the full detector.
//

public struct CameraFusionHead: DomainHead {
    public let domain: DetectionDomain = .camera
    public init() {}

    public func verdict(_ s: DetectionSignals) throws -> InferenceResult {
        switch s.config.baseExpert {
        case .fusion: return try Fusion.run(cgImage: s.cgImage, config: s.config)
        case .warp: return try WarpBase.run(s)
        }
    }
}
