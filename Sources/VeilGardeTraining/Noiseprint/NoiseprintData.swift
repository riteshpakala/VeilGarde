//
//  NoiseprintData.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What the noiseprint learns from: camera originals against everything that is not a
//        direct capture (the v202 camera-vs-everything design: if the net cannot beat
//        camera-origin web reals it is not a camera-present signal). Each negative family is a
//        folder; images are listed, shuffled with a seed, and split image-disjoint per family,
//        three to one, as the reference split them.
//  PIN:  the reference trainer (v202_noiseprint.py): the camera folder in full (438 iPhone originals, the
//        first 350 for training), 120 images per negative family (90 train, 30 test), one
//        CPython Random(0) stream shuffling the camera list, then each family in order, then the
//        pooled negative training list. The reference listed with glob (directory order); the listing here is
//        sorted first, so the same folder gives the same split on any Mac. The reference's six families were
//        ai_photo, ai_art, web_real, screenshot, shot_render and cgi; the atlas pools behind
//        ai_art, shot_render and cgi were deleted from the T9 in the features-only cleanup, so
//        ai_art reads Midjourney v6 images (mj_pool) instead, shot_render and cgi have no
//        surviving images, and ai_video (Sora, Hailuo and other video frames) is added. photoreal
//        (2026-10-19) is the forgeries the first retrain missed: photoreal AI images from Instagram
//        at full resolution, the family the adversarial anchor comes from. It is listed last, so
//        the families before it keep their splits draw for draw. A split excludes the files it is
//        given (the anchor) from every folder, by path and by content, so the image the test
//        scores never trains the net. Every report names the families that ran and what was
//        excluded.
//

import Foundation
import VeilGardeCore

public struct NoiseprintFamily: Codable, Sendable, Equatable {
    public var name: String
    public var directory: String
    public var note: String?

    public init(_ name: String, _ directory: String, note: String? = nil) {
        self.name = name
        self.directory = directory
        self.note = note
    }
}

public struct NoiseprintSources: Codable, Sendable, Equatable {
    public var camera: String
    public var negatives: [NoiseprintFamily]
    public var cameraTrain = 350
    public var perFamily = 120
    public var seed: UInt64 = 0

    public init(camera: String, negatives: [NoiseprintFamily]) {
        self.camera = camera
        self.negatives = negatives
    }

    /// The folders under the datasets root (VEILGARDE_DATASETS, else the work area's datasets/) that stand where the
    /// reference's stood.
    public static var standard: NoiseprintSources { standard(under: WorkArea.datasets() ?? URL(fileURLWithPath: "datasets", isDirectory: true)) }

    public static func standard(under root: URL) -> NoiseprintSources {
        let d = root.standardizedFileURL.path
        return NoiseprintSources(camera: "\(d)/iphone", negatives: [
            NoiseprintFamily("ai_photo", "\(d)/final_mixed/generated"),
            NoiseprintFamily("ai_art", "\(d)/mj_pool/img", note: "Midjourney v6, standing in for the deleted atlas/art/generated"),
            NoiseprintFamily("web_real", "\(d)/final_mixed/real", note: "camera-origin but laundered: the family that decides whether this is a camera-present signal"),
            NoiseprintFamily("screenshot", "\(d)/reel_screenshots"),
            NoiseprintFamily("ai_video", "\(d)/aivideo_showcase_pool/frames", note: "added: no shot-render or CGI images survive"),
            NoiseprintFamily("photoreal", "\(d)/ig_fullres/generated",
                             note: "added: photoreal AI from Instagram at full resolution, the forgeries a camera-present signal must not read as cameras"),
        ])
    }

    /// The reference families with no surviving images, for the report.
    public static let unavailableFamilies = ["shot_render (atlas/shots)", "cgi (atlas/cgi)"]
}

/// The images each split draws on.
public struct NoiseprintSplit: Sendable, Equatable {
    public var cameraTrain: [URL]
    public var cameraTest: [URL]
    /// Pooled and shuffled, as the reference trained on them.
    public var negativeTrain: [URL]
    /// Per family, in family order.
    public var negativeTest: [(family: String, urls: [URL])]
    /// Per family: images found, used for training, held out.
    public var counts: [String: [Int]]
    /// The files left out of every folder because they matched an excluded file, by path or content.
    public var excluded: [String] = []

    public static func == (a: NoiseprintSplit, b: NoiseprintSplit) -> Bool {
        a.cameraTrain == b.cameraTrain && a.cameraTest == b.cameraTest && a.negativeTrain == b.negativeTrain && a.counts == b.counts && a.excluded == b.excluded
            && a.negativeTest.map(\.family) == b.negativeTest.map(\.family) && a.negativeTest.map(\.urls) == b.negativeTest.map(\.urls)
    }
}

extension NoiseprintSources {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "webp"]

    /// Every image under `directory`, sorted by path (resource forks and dot files left out).
    public static func list(_ directory: String) -> [URL] {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker where extensions.contains(url.pathExtension.lowercased()) && !url.lastPathComponent.hasPrefix("._") {
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Files a split leaves out wherever they are: by path, and by content (size, then SHA-256), so
    /// a copy under another name is left out too.
    struct Exclusion {
        var paths = Set<String>()
        var contents: [Int: Set<String>] = [:]

        init(_ files: [String]) {
            for file in files {
                let url = URL(fileURLWithPath: file).standardizedFileURL
                paths.insert(url.path)
                if let size = Self.size(url), let sha = try? ContentHash.sha256Hex(fileAt: url) { contents[size, default: []].insert(sha) }
            }
        }

        func contains(_ url: URL) -> Bool {
            if paths.contains(url.standardizedFileURL.path) { return true }
            guard let size = Self.size(url), let shas = contents[size] else { return false }
            return (try? ContentHash.sha256Hex(fileAt: url)).map(shas.contains) ?? false
        }

        static func size(_ url: URL) -> Int? { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
    }

    /// The reference split over these folders: the camera list, then each family, shuffled from one
    /// stream, with `excluding` (paths) left out of every list before it is shuffled.
    public func split(excluding: [String] = []) throws -> NoiseprintSplit {
        var rng = PythonRandom(seed: seed)
        let exclusion = Exclusion(excluding)
        var excluded: [String] = []
        func listed(_ directory: String) -> [URL] {
            let all = Self.list(directory)
            guard !excluding.isEmpty else { return all }
            let kept = all.filter { !exclusion.contains($0) }
            if kept.count < all.count { excluded += Set(all).subtracting(kept).map(\.path).sorted() }
            return kept
        }
        var camera = listed(self.camera)
        guard camera.count > cameraTrain else {
            throw VeilGardeFailure.missing("the camera folder \(self.camera) holds \(camera.count) images; the split needs more than \(cameraTrain)")
        }
        rng.shuffle(&camera)
        let trainShare = perFamily * 3 / 4
        var negTrain: [URL] = [], negTest: [(String, [URL])] = []
        var counts: [String: [Int]] = ["camera": [camera.count, cameraTrain, camera.count - cameraTrain]]
        for family in negatives {
            var files = listed(family.directory)
            let found = files.count
            rng.shuffle(&files)
            files = Array(files.prefix(perFamily))
            let train = Array(files.prefix(trainShare)), test = Array(files.dropFirst(trainShare))
            negTrain += train
            negTest.append((family.name, test))
            counts[family.name] = [found, train.count, test.count]
        }
        rng.shuffle(&negTrain)
        return NoiseprintSplit(cameraTrain: Array(camera.prefix(cameraTrain)), cameraTest: Array(camera.dropFirst(cameraTrain)),
                               negativeTrain: negTrain, negativeTest: negTest, counts: counts, excluded: excluded)
    }
}
