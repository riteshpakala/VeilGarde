//
//  Gate.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What an acquired image must be before its features are kept: decodable, at least 512 px
//        on its short native side, at least 20,000 bytes, not already in the store (the SHA-1 of
//        its bytes is the row id), and not a near-copy of a stored or just-accepted image (its
//        64-bit difference hash within 2 bits for faces, 4 otherwise).
//  PIN:  atlas_verify.py's structural gate and dedup chain, with the store's ids for its md5
//        index. The difference hash is CoreGraphics', computed the same way as the Python PIL one
//        (9×8 gray, horizontal gradient bits, row-major) but not bit-identical to it; the seed rows
//        carry no hash, so only VeilGarde's own rows are compared.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens

public enum GateVerdict: Equatable, Sendable {
    case accepted(id: String, image: CGImage, dhash: UInt64)
    case rejected(String)

    public static func == (a: GateVerdict, b: GateVerdict) -> Bool {
        switch (a, b) {
        case (.accepted(let x, _, let p), .accepted(let y, _, let q)): return x == y && p == q
        case (.rejected(let x), .rejected(let y)): return x == y
        default: return false
        }
    }

    public var reason: String? { if case .rejected(let r) = self { return r } else { return nil } }
}

public final class AcquireGate {
    public static let minimumSide = 512
    public static let minimumBytes = 20_000

    private var ids: Set<String>
    private var hashes: [UInt64]

    /// Seeded with the store's ids and the dHashes its rows carry.
    public init(store: FeatureStore) throws {
        ids = try store.ids()
        hashes = []
        for name in store.shardNames() {
            let rows = try JSONDecoder().decode([FeatureRow].self, from: Data(contentsOf: FeatureShard.metaURL(store.directory, name)))
            hashes += rows.compactMap { $0.dhash.flatMap { UInt64($0, radix: 16) } }
        }
    }

    public init(ids: Set<String> = [], hashes: [UInt64] = []) {
        self.ids = ids
        self.hashes = hashes
    }

    public func check(_ data: Data, category: String) -> GateVerdict {
        guard data.count >= Self.minimumBytes else { return .rejected("tiny") }
        let id = ContentHash.sha1Hex(data)
        guard !ids.contains(id) else { return .rejected("dup") }
        guard let cg = try? ImageDecoding.cgImage(data: data) else { return .rejected("decode") }
        guard min(cg.width, cg.height) >= Self.minimumSide else { return .rejected("min_side") }
        let h = Self.dhash(cg)
        let limit = category == "human" ? 2 : 4
        if hashes.contains(where: { ($0 ^ h).nonzeroBitCount <= limit }) { return .rejected("near_dup") }
        return .accepted(id: id, image: cg, dhash: h)
    }

    /// Records an accepted image so a later copy in the same run is rejected.
    public func admit(id: String, dhash: UInt64) {
        ids.insert(id)
        hashes.append(dhash)
    }

    /// The 64-bit difference hash: the image drawn 9×8 in gray, a bit per horizontal step that falls.
    public static func dhash(_ cg: CGImage) -> UInt64 {
        var px = [UInt8](repeating: 0, count: 9 * 8)
        guard let ctx = CGContext(data: &px, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        var bits: UInt64 = 0
        for r in 0..<8 { for c in 0..<8 { bits = (bits << 1) | (px[r * 9 + c] > px[r * 9 + c + 1] ? 1 : 0) } }
        return bits
    }
}
