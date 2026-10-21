//
//  CameraFusionHead.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The camera domain's base expert: the fusion head over DINOv2 and the capture signature,
//        the spine the specialist stack compounds onto. Registered by default and the fallback for
//        any domain without its own head.
//

public struct CameraFusionHead: DomainHead {
    public let domain: DetectionDomain = .camera
    public init() {}

    public func verdict(_ s: DetectionSignals) throws -> InferenceResult {
        try Fusion.verdict(s)
    }
}
