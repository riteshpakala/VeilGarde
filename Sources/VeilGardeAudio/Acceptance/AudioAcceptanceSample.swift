//
//  AudioAcceptanceSample.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The clips an acceptance runs on: the audio files an argument names (a folder searched
//        recursively, a text file of paths, or one file), each cut into consecutive segments of a
//        fixed length, a seeded sample of them, and their loading.
//  PIN:  Segments start at 0 and run back to back; the last partial one is dropped; a track
//        shorter than one segment yields none. The sample is SplitMix64(seed).permutation's first n,
//        kept in folder order, so the cross match's "next clip" is usually a neighbouring segment of
//        the same track: the hardest false-match case, said in the report. Each file is decoded once
//        for all its sampled segments.
//

import Foundation
import VeilGardeCore

public enum AudioAcceptanceSample {
    public struct Item: Sendable, Equatable, Codable {
        public var url: URL
        public var segment: Int
        public var startSeconds: Double
        /// nil: the whole file.
        public var durationSeconds: Double?

        public init(url: URL, segment: Int, startSeconds: Double, durationSeconds: Double?) {
            self.url = url
            self.segment = segment
            self.startSeconds = startSeconds
            self.durationSeconds = durationSeconds
        }

        public var label: String { durationSeconds == nil ? url.lastPathComponent : "\(url.lastPathComponent)#\(segment)" }
    }

    /// The audio files `input` names: a text file of paths (`#` comments), a folder (recursive,
    /// sorted by path, exFAT sidecars skipped) or one file.
    public static func files(in input: URL) throws -> [URL] {
        if input.pathExtension.lowercased() == "txt" {
            let text = try String(contentsOf: input, encoding: .utf8)
            return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
            throw VeilGardeFailure.missing("no audio file or folder at \(input.path)")
        }
        guard isDirectory.boolValue else { return [input] }
        var out: [URL] = []
        let walker = FileManager.default.enumerator(at: input, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let next = walker?.nextObject() as? URL {
            guard !next.lastPathComponent.hasPrefix("._"), AudioFiles.extensions.contains(next.pathExtension.lowercased()) else { continue }
            out.append(next)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// How many segments of `segment` seconds a track of `total` seconds holds.
    public static func segments(total: Double, segment: Double) -> Int { segment > 0 && total > 0 ? Int(total / segment) : 0 }

    /// Every segment of every file, in file order; `segmentSeconds` nil or 0 keeps whole files.
    public static func items(for files: [URL], segmentSeconds: Double?) throws -> [Item] {
        var out: [Item] = []
        for url in files {
            guard let segment = segmentSeconds, segment > 0 else {
                out.append(Item(url: url, segment: 0, startSeconds: 0, durationSeconds: nil))
                continue
            }
            let info = try AudioFiles.info(of: url)
            for k in 0..<segments(total: info.seconds, segment: segment) {
                out.append(Item(url: url, segment: k, startSeconds: Double(k) * segment, durationSeconds: segment))
            }
        }
        return out
    }

    /// At most `n` of `items`, chosen by the seed, in the items' order.
    public static func sample(_ items: [Item], n: Int, seed: UInt64) -> [Item] {
        guard items.count > n else { return items }
        var rng = SplitMix64(seed: seed)
        let picked = Set(rng.permutation(items.count).prefix(max(0, n)))
        return items.enumerated().filter { picked.contains($0.offset) }.map(\.element)
    }

    /// The items' clips, each file decoded once.
    public static func load(_ items: [Item], note: (String) -> Void = { _ in }) throws -> [(item: Item, clip: AudioClip)] {
        var out: [(Item, AudioClip)] = []
        var current: (URL, AudioClip)? = nil
        for item in items {
            if current?.0 != item.url {
                current = (item.url, try AudioFiles.read(item.url))
                note("accept: decoded \(item.url.lastPathComponent)")
            }
            guard let whole = current?.1 else { continue }
            if let duration = item.durationSeconds {
                out.append((item, AudioTransforms.cut(whole, startSample: Int(item.startSeconds * whole.sampleRate), length: Int(duration * whole.sampleRate))))
            } else {
                out.append((item, whole))
            }
        }
        return out
    }
}
