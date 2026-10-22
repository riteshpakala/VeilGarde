//
//  FeatureRow.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: One image in the features-only store, as metadata: its id (the SHA-1 of its bytes), where
//        it came from, its label and category, and what the flywheel needs to train and audit a
//        head. The image itself is never kept; its features sit in the shard's columns.
//  PIN:  The <shard>_meta.json row, read and written as is. The seed store's rows carry the first
//        keys; a row the flywheel writes adds its provenance (source id and URL, licence, native
//        size, dHash, the CLIP route scores). A key not listed here is ignored on read and not
//        written back. label: 1 generated, 0 real.
//

public struct FeatureRow: Codable, Sendable, Equatable {
    public var id: String
    public var path: String
    public var label: Int
    public var category: String
    public var source: String?
    public var nsfw: Bool
    public var golden: Bool
    public var genFamily: String?
    public var generator: String?
    public var split: String?
    public var relabel: String?
    public var weak: Bool?
    public var sourceID: String?
    public var sourceURL: String?
    public var license: String?
    public var width: Int?
    public var height: Int?
    /// The 64-bit difference hash, hex, for near-duplicate rejection without the image.
    public var dhash: String?
    /// The category router's scores over its prompts, when the row was routed.
    public var route: [Float]?

    public init(id: String, path: String, label: Int, category: String, source: String?, nsfw: Bool = false, golden: Bool = false,
                genFamily: String? = nil, generator: String? = nil, split: String? = nil, relabel: String? = nil, weak: Bool? = nil,
                sourceID: String? = nil, sourceURL: String? = nil, license: String? = nil,
                width: Int? = nil, height: Int? = nil, dhash: String? = nil, route: [Float]? = nil) {
        self.id = id
        self.path = path
        self.label = label
        self.category = category
        self.source = source
        self.nsfw = nsfw
        self.golden = golden
        self.genFamily = genFamily
        self.generator = generator
        self.split = split
        self.relabel = relabel
        self.weak = weak
        self.sourceID = sourceID
        self.sourceURL = sourceURL
        self.license = license
        self.width = width
        self.height = height
        self.dhash = dhash
        self.route = route
    }

    enum CodingKeys: String, CodingKey {
        case id, path, label, category, source, nsfw, golden, generator, split, relabel, weak, license, width, height, dhash, route
        case genFamily = "gen_family"
        case sourceID = "src_id"
        case sourceURL = "src_url"
    }

    public var isGenerated: Bool { label == 1 }
}

/// The store's columns, by name and width, in the order a shard lists them.
public enum FeatureColumn: String, Codable, Sendable, CaseIterable {
    /// DINOv2 CLS after the 360×640 force-resize: what the linear heads read.
    case dinoNorm = "dino_norm"
    /// DINOv2 CLS after the plain preprocessing: what the camera head reads.
    case dinoFusion = "dino_fusion"
    /// The nine capture values.
    case cap

    public var width: Int {
        switch self {
        case .dinoNorm, .dinoFusion: return 384
        case .cap: return CaptureFeatures.count
        }
    }
}
