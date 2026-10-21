//
//  Images.swift
//  VeilGardePlayground
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The images the playground runs: the two parity crops and VeilGarde's own route goldens for
//        them (written 2026-10-21 with the shipped bundle), and, when the T9 is mounted, a seeded
//        sample of iPhone originals and generated images from final_mixed (read only).
//

import Foundation
import VeilGarde

struct PlaygroundImage {
    let name: String
    let url: URL
    /// 0 real, 1 generated, nil unknown.
    let label: Int?
    /// VeilGarde's route golden for this image, when it is a parity crop.
    let golden: URL?
}

enum Images {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "Playground" { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent()
    }()

    static let goldens = repoRoot.appendingPathComponent("Tests/VeilGardeInferenceTests/Fixtures/crops")
    /// final_mixed under VEILGARDE_DATASETS (else the work area's datasets/), for the optional labelled sample.
    static let finalMixed = (WorkArea.datasets() ?? URL(fileURLWithPath: "datasets", isDirectory: true)).appendingPathComponent("final_mixed")

    static var parityCrops: [PlaygroundImage] {
        ["crop_ben", "crop_fox"].map {
            PlaygroundImage(name: "\($0).png", url: goldens.appendingPathComponent("\($0).png"), label: nil, golden: goldens.appendingPathComponent("\($0).route.json"))
        }
    }

    /// Up to `perClass` iPhone originals and generated images, every k-th by name.
    static func sample(perClass: Int = 6) -> [PlaygroundImage] {
        var out: [PlaygroundImage] = []
        for (folder, prefix, label) in [("real", "iphone_real_", 0), ("generated", "", 1)] {
            let dir = finalMixed.appendingPathComponent(folder)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { !$0.hasPrefix(".") && $0.hasPrefix(prefix) && ["jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
            guard !names.isEmpty else { continue }
            let step = max(1, names.count / perClass)
            for name in names.enumerated().filter({ $0.offset % step == 0 }).prefix(perClass).map(\.element) {
                out.append(PlaygroundImage(name: name, url: dir.appendingPathComponent(name), label: label, golden: nil))
            }
        }
        return out
    }
}
