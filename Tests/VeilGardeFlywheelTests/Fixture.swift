//
//  Fixture.swift
//  VeilGardeFlywheelTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A throwaway flywheel work area: live/ seeded from a copy of the shipped bundle, a seeded
//        synthetic store with golden anchors, and a battery whose verdicts are canned, so promote,
//        rollback and the policy run without the GPU or an image.
//

import Foundation
import VeilGardeCore
@testable import VeilGardeFlywheel

enum Fixture {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "Tests" { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent()
    }()

    static let resources = repoRoot.appendingPathComponent("Sources/VeilGardeInference/Resources")
}

final class FlywheelFixture {
    let root: URL
    let area: FlywheelArea
    /// The battery's one image, and the verdict the canned source gives it.
    let probe: URL
    let verdicts: CannedVerdicts

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vg-flywheel-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        area = FlywheelArea(WorkArea(root: root.appendingPathComponent("area", isDirectory: true)))
        // The battery: one HARD group of one image that must read real.
        probe = root.appendingPathComponent("probe.jpg")
        try Data("probe".utf8).write(to: probe)
        verdicts = CannedVerdicts([probe.path: BatteryVerdict(prediction: "real", p: 0.2, semanticScore: 0.1, capturePresent: false)])
        let spec = BatterySpec(groups: [BatterySpec.Group(name: "protect_real", mode: .hard, want: "real", paths: [probe.path])])
        let baseline = ["protect_real": BatteryGroupResult(acc: 1, n: 1, mode: .hard, want: "real")]
        let shipped = try ModelBundle.load(Fixture.resources)
        try area.initialize(from: shipped, spec: try JSONEncoder().encode(spec), baseline: try JSONEncoder().encode(baseline))
        try Self.writeStore(area.store)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// The battery promote runs: the canned source on the work area's spec.
    var battery: Promoter.Battery {
        { [area, verdicts] gate, _ in
            try BatteryRunner.run(spec: try BatterySpec.load(area.batterySpec), specURL: area.batterySpec, gate: gate,
                                  baselineURL: area.batteryBaseline, verdicts: verdicts)
        }
    }

    func fail() { verdicts.verdicts[probe.path] = BatteryVerdict(prediction: "generated", p: 0.9, semanticScore: 0.9, capturePresent: false) }

    static func writeStore(_ directory: URL) throws {
        var rng = SplitMix64(seed: 3)
        func gauss() -> Float { Float((-2 * log(max(1e-12, rng.unit()))).squareRoot() * cos(2 * .pi * rng.unit())) }
        let sources = ["civitai", "commons_native", "inat", "hf_faces", "wikimedia", "openverse"]
        var rows: [FeatureRow] = []
        var columns: [FeatureColumn: [Float]] = Dictionary(uniqueKeysWithValues: FeatureColumn.allCases.map { ($0, [Float]()) })
        let plan: [(String, Int, Int)] = [("art", 1, 120), ("art", 0, 90), ("blur", 1, 80), ("blur", 0, 60), ("human", 1, 120), ("human", 0, 150),
                                          ("cgi", 1, 70), ("cgi", 0, 60), ("photo", 0, 160)]
        var serial = 0
        for (category, label, n) in plan {
            for _ in 0..<n {
                serial += 1
                let golden = label == 0 && category == "photo" && serial % 5 == 0
                rows.append(FeatureRow(id: ContentHash.sha1Hex(Data("row-\(serial)".utf8)), path: "/pools/\(category)/\(serial).jpg", label: label,
                                       category: category, source: sources[serial % sources.count], golden: golden))
                let c = ["art": 0, "blur": 1, "human": 2, "cgi": 3, "photo": 4][category]!
                var norm = (0..<384).map { _ in gauss() }
                if label == 1 { for j in (c * 12)..<(c * 12 + 12) { norm[j] += 1.6 } }
                columns[.dinoNorm]! += norm
                columns[.dinoFusion]! += (0..<384).map { j in gauss() + (label == 1 && j < 10 ? 1 : 0) }
                columns[.cap]! += [Float(rng.unit() * 40), 1, 0, 2000, 5, 0.5, 0.5, 0.5, 0]
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FeatureShard(name: "synthetic", rows: rows, columns: columns).write(to: directory)
    }
}
