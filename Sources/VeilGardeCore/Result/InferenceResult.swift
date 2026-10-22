//
//  InferenceResult.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Everything the detector says about one image: one verdict (its P(AI) and the label read
//        from it at threshold ± band), the image's size, every stack member's output in the
//        pipeline's order, every revision's record in its order, and the hashes of the bundle it
//        ran. ResultJSON writes it as the schema-v1 JSON the command line, the battery and the
//        goldens read.
//

/// The hashes of what a result was computed with (the result JSON's `bundle` block).
public struct BundleHashes: Sendable, Equatable {
    public let manifestSHA256: String
    /// Every artifact's SHA-256 by its slot: "camera", "combiner", "head:art", …
    public let artifacts: [String: String]

    public init(manifestSHA256: String, artifacts: [String: String]) {
        self.manifestSHA256 = manifestSHA256
        self.artifacts = artifacts
    }
}

public struct InferenceResult: Sendable {
    /// "generated" | "real" | "inconclusive".
    public let prediction: String
    /// P(AI).
    public let p: Float
    public let threshold: Float
    public let band: Float
    /// The image's native size.
    public let imageWidth: Int
    public let imageHeight: Int
    /// Every member's output, in the pipeline's order.
    public let stack: [MemberOutput]
    /// Every revision's record, in the order they ran.
    public let revisions: [RevisionRecord]
    public let bundle: BundleHashes?

    public init(prediction: String, p: Float, threshold: Float, band: Float, imageWidth: Int, imageHeight: Int,
                stack: [MemberOutput] = [], revisions: [RevisionRecord] = [], bundle: BundleHashes? = nil) {
        self.prediction = prediction
        self.p = p
        self.threshold = threshold
        self.band = band
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.stack = stack
        self.revisions = revisions
        self.bundle = bundle
    }
}
