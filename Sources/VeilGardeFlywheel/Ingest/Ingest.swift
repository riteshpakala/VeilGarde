//
//  Ingest.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Local labeled images into the store: a manifest of {path, label, category, source?,
//        golden?, gen_family?} measured into one new shard (DINOv2's two views and the capture
//        values), the images read and dropped.
//  PIN:  ShardExtractor does the work (the trainer's own extraction), so a row ingested here is
//        a row the trainers can read; ids already in the store are skipped; nothing is deleted.
//

import Foundation
import VeilGardeCore

public enum Ingest {
    public static func run(_ items: [ExtractionItem], shard: String, area: FlywheelArea, variant: DinoVariant = .small,
                           note: (String) -> Void = { _ in }) throws -> ShardExtraction {
        return try ShardExtractor.extract(items, shard: shard, store: FeatureStore(directory: area.store), extractor: FeatureExtractor(variant: variant), note: note)
    }
}
