//
//  InferenceResult.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Everything the detector says about one image: one verdict (its P(AI) and the label read
//        from it at threshold ± band), the capture signature, the specialists that weighed in, the
//        semantic tiles, the route trace and the hashes of the bundle it ran. ResultJSON writes it
//        as the schema-v3 JSON the command line, the battery and the goldens read.
//

/// The hashes of what a routed result was computed with (the result JSON's `bundle` block).
public struct BundleHashes: Sendable, Equatable {
    public let fusionHeadSHA256: String?
    public let combinerSHA256: String?
    public let manifestSHA256: String

    public init(fusionHeadSHA256: String?, combinerSHA256: String?, manifestSHA256: String) {
        self.fusionHeadSHA256 = fusionHeadSHA256
        self.combinerSHA256 = combinerSHA256
        self.manifestSHA256 = manifestSHA256
    }
}

public struct InferenceResult: Sendable {
    /// The base expert that ran: "fusion", or "screenshot" (the content head, or the flat-UI guard
    /// inside the camera base).
    public let scorer: String
    /// "generated" | "real" | "inconclusive".
    public let prediction: String
    /// P(AI).
    public let p: Float
    public let threshold: Float
    public let band: Float
    /// The image's native size.
    public let imageWidth: Int
    public let imageHeight: Int
    public let captureSignature: CaptureSignature?
    public let specialists: [SpecialistContribution]?
    /// Per-patch-token P(generated) on DINOv2's 16×16 grid.
    public let semanticTiles: [[Float]]?
    public let routeDiagnostics: RouteDiagnostics?
    public let bundle: BundleHashes?

    public init(scorer: String, prediction: String, p: Float, threshold: Float, band: Float, imageWidth: Int, imageHeight: Int,
                captureSignature: CaptureSignature? = nil, specialists: [SpecialistContribution]? = nil, semanticTiles: [[Float]]? = nil,
                routeDiagnostics: RouteDiagnostics? = nil, bundle: BundleHashes? = nil) {
        self.scorer = scorer
        self.prediction = prediction
        self.p = p
        self.threshold = threshold
        self.band = band
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.captureSignature = captureSignature
        self.specialists = specialists
        self.semanticTiles = semanticTiles
        self.routeDiagnostics = routeDiagnostics
        self.bundle = bundle
    }
}
