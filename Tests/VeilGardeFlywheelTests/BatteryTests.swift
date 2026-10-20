//
//  BatteryTests.swift
//  VeilGardeFlywheelTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The battery's spec and rules: the shipped spec and floors are the pinned v2 bytes and
//        decode (the atlas groups retired, v1's floors kept); `{IMAGES}` resolves from the
//        environment, then the work area; a newer pair replaces an older one without losing it; a
//        group's files resolve as the Python battery's glob, filters and order resolve them; every
//        mode gates the way run_full gates; the input-set hash equals Python's.
//

import Foundation
import Testing
import VeilGardeCore
@testable import VeilGardeFlywheel

@Suite("Battery")
struct BatteryTests {
    @Test("the shipped spec and floors are pinned, byte for byte, and decode")
    func shipped() throws {
        let spec = try FlywheelResources.batterySpec(), floors = try FlywheelResources.batteryBaseline()
        #expect(ContentHash.sha256Hex(spec) == FlywheelResources.batterySpecSHA256)
        #expect(ContentHash.sha256Hex(floors) == FlywheelResources.batteryBaselineSHA256)
        let s = try JSONDecoder().decode(BatterySpec.self, from: spec)
        #expect(s.version == 2 && s.groups.count == 8 && s.tolerance == 0.001)
        #expect(s.groups.filter { $0.mode.isHard }.map(\.name) == ["user_real", "native_12yrs", "flux_anchor", "user_gen", "native_cam", "lion_hard"])
        #expect(s.groups.filter { !$0.mode.isHard }.map(\.name) == ["gen_semantic", "wildlife_real"])
        let everyPattern = s.groups.flatMap { ($0.paths ?? []) + ($0.globs ?? []) }
        #expect(everyPattern.allSatisfy { $0.hasPrefix("{IMAGES}/") }, "every image is under {IMAGES}")
        let raw = try JSONSerialization.jsonObject(with: spec) as! [String: Any]
        let retired = (raw["retired"] as? [String: Any])?["groups"] as? [String] ?? []
        #expect(retired.count == 12 && retired.allSatisfy { $0.hasPrefix("atlas_") })
        let b = try JSONDecoder().decode([String: BatteryGroupResult].self, from: floors)
        #expect(b["user_real"]?.acc == 1.0 && b["user_real"]?.mode == .hard)
        #expect(b["wildlife_real"]?.acc == 1.0 && b["wildlife_real"]?.semAcc == 0.9230769230769231, "v1's floor, unchanged")
        #expect(b["gen_semantic"]?.acc == 1.0 && b["gen_semantic"]?.semAcc == 1.0)
        #expect(Set(b.keys).isSubset(of: Set(s.groups.map(\.name))), "no floor for a retired group")
    }

    @Test("{IMAGES} is the environment's folder, else the work area's, else the spec's")
    func imagesVar() {
        let spec = BatterySpec(vars: ["IMAGES": "/default/images"], groups: [])
        let area = URL(fileURLWithPath: "/area/battery/images")
        #expect(spec.resolvedVars(environment: [:])["IMAGES"] == "/default/images")
        #expect(spec.resolvedVars(environment: [:], images: area)["IMAGES"] == "/area/battery/images")
        #expect(spec.resolvedVars(environment: [BatterySpec.imagesKey: "/named"], images: area)["IMAGES"] == "/named")
        #expect(spec.resolvedVars(environment: [BatterySpec.imagesKey: ""], images: area)["IMAGES"] == "/area/battery/images", "an empty override is no override")
    }

    @Test("a newer spec and floors replace the old pair, which is kept")
    func replace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vg-battery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let area = FlywheelArea(WorkArea(root: dir))
        let old = try JSONEncoder().encode(BatterySpec(version: 1, groups: [])), oldFloors = Data("{}".utf8)
        try FileManager.default.createDirectory(at: area.battery, withIntermediateDirectories: true)
        try old.write(to: area.batterySpec)
        try oldFloors.write(to: area.batteryBaseline)
        let spec = try FlywheelResources.batterySpec(), floors = try FlywheelResources.batteryBaseline()
        let first = try area.replaceBattery(spec: spec, baseline: floors, date: Date(timeIntervalSince1970: 0))
        #expect(first.batterySpecSHA256 == FlywheelResources.batterySpecSHA256 && first.batteryBaselineSHA256 == FlywheelResources.batteryBaselineSHA256)
        let kept = try #require(first.retired.map { URL(fileURLWithPath: $0) })
        #expect(try Data(contentsOf: kept.appendingPathComponent("spec.json")) == old)
        #expect(try Data(contentsOf: kept.appendingPathComponent("baseline.json")) == oldFloors)
        let again = try area.replaceBattery(spec: spec, baseline: floors, date: Date(timeIntervalSince1970: 1))
        #expect(again.retired == nil, "installing the same pair twice retires nothing")
        #expect(!FileManager.default.fileExists(atPath: area.live.path), "live/ is never touched")
    }

    @Test("groups resolve as the Python battery resolves them")
    func resolve() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vg-battery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["b.jpg", "a.jpg", "C.jpg", "a_shot.jpg", "._a.jpg", ".hidden.jpg", "x.PNG", "y.png", "z.txt"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let spec = BatterySpec(vars: ["D": dir.path], groups: [
            .init(name: "jpgs", mode: .ratchet, want: "real", paths: ["{D}/extra.jpg"], globs: ["{D}/*.jpg"], excludeSubstr: "_shot"),
            .init(name: "shots", mode: .taxonomy, want: "generated", globs: ["{D}/*.jpg"], includeSubstr: "_shot", skipIfEmpty: true),
            .init(name: "upper", mode: .hard, want: "generated", globs: ["{D}/*.PNG", "{D}/[xy].p?g"]),
            .init(name: "none", mode: .taxonomy, want: "real", globs: ["{D}/*.gif"], skipIfEmpty: true),
        ])
        let full = try spec.resolve(gate: .full, vars: spec.vars)
        #expect(full.map(\.name) == ["jpgs", "shots", "upper"])
        #expect(full[0].files == ["C.jpg", "a.jpg", "b.jpg"].map { dir.path + "/" + $0 } + [dir.path + "/extra.jpg"])
        #expect(full[1].files == [dir.path + "/a_shot.jpg"])
        #expect(full[2].files == [dir.path + "/x.PNG", dir.path + "/y.png"], "names match case-sensitively")
        #expect(try spec.resolve(gate: .promote, vars: spec.vars).map(\.name) == ["upper"])
        #expect(BatterySpec.fnmatch("abc", "a[!x]c") && !BatterySpec.fnmatch("axc", "a[!x]c") && BatterySpec.fnmatch("a5", "a[0-9]"))
    }

    func run(_ groups: [BatterySpec.Group], _ verdicts: [String: BatteryVerdict], floors: [String: BatteryGroupResult]?,
             failures: Set<String> = [], gate: BatterySpec.Gate = .full, rebaseline: Bool = false) throws -> BatteryReport {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vg-battery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var resolved = [String: BatteryVerdict]()
        var fail = Set<String>()
        var specGroups = groups
        for i in specGroups.indices {
            specGroups[i].paths = (specGroups[i].paths ?? []).map { name in
                let path = dir.appendingPathComponent(name).path
                try? Data(name.utf8).write(to: URL(fileURLWithPath: path))
                if let v = verdicts[name] { resolved[path] = v }
                if failures.contains(name) { fail.insert(path) }
                return path
            }
        }
        let baselineURL = dir.appendingPathComponent("baseline.json")
        if let floors { try JSONEncoder().encode(floors).write(to: baselineURL) }
        return try BatteryRunner.run(spec: BatterySpec(groups: specGroups), gate: gate, baselineURL: baselineURL,
                                     verdicts: CannedVerdicts(resolved, failures: fail), rebaseline: rebaseline)
    }

    static func v(_ w: String, sem: Double? = nil) -> BatteryVerdict { BatteryVerdict(weighted: w, weightedScore: w == "real" ? 0.2 : 0.8, semanticScore: sem, capturePresent: false) }

    @Test("HARD, HARD_SEM, RATCHET, RATCHET_SEM and TAXONOMY gate as run_full gates")
    func modes() throws {
        let groups: [BatterySpec.Group] = [
            .init(name: "hard", mode: .hard, want: "real", paths: ["h1", "h2"]),
            .init(name: "hardsem", mode: .hardSemantic, want: "generated", paths: ["s1"]),
            .init(name: "ratchet", mode: .ratchet, want: "real", paths: ["r1", "r2", "r3", "r4"]),
            .init(name: "ratchetsem", mode: .ratchetSemantic, want: "generated", paths: ["t1", "t2"]),
            .init(name: "taxonomy", mode: .taxonomy, want: "generated", paths: ["x1"]),
        ]
        let floors: [String: BatteryGroupResult] = [
            "ratchet": .init(acc: 0.75, n: 4, mode: .ratchet, want: "real"),
            "ratchetsem": .init(acc: 0.5, n: 2, semAcc: 1.0, mode: .ratchetSemantic, want: "generated"),
        ]
        let good: [String: BatteryVerdict] = ["h1": Self.v("real"), "h2": Self.v("real"), "s1": Self.v("generated", sem: 0.9),
            "r1": Self.v("real"), "r2": Self.v("real"), "r3": Self.v("real"), "r4": Self.v("generated"),
            "t1": Self.v("generated", sem: 0.8), "t2": Self.v("real", sem: 0.7), "x1": Self.v("real")]
        let pass = try run(groups, good, floors: floors)
        #expect(pass.pass, "\(pass.table)")
        #expect(pass.statuses.map(\.status) == ["PASS", "PASS", "PASS", "PASS", "·"])
        #expect(pass.groups["ratchet"]?.acc == 0.75 && pass.groups["ratchetsem"]?.semAcc == 1.0)
        #expect(pass.table.hasSuffix("BATTERY: PASS"))

        var bad = good; bad["h2"] = Self.v("generated")
        #expect(try run(groups, bad, floors: floors).statuses[0].status == "FAIL")
        bad = good; bad["s1"] = Self.v("generated", sem: nil)
        let noSem = try run(groups, bad, floors: floors)
        #expect(!noSem.pass && noSem.statuses[1].status == "FAIL(sem)", "a HARD_SEM group without semantic tiles fails")
        bad = good; bad["r3"] = Self.v("generated")
        #expect(try run(groups, bad, floors: floors).statuses[2].status == "FAIL(<0.75)")
        bad = good; bad["t1"] = Self.v("generated", sem: 0.2)
        #expect(try run(groups, bad, floors: floors).statuses[3].status == "FAIL(sem)")
        bad = good; bad["x1"] = Self.v("generated")
        #expect(try run(groups, bad, floors: floors).pass, "TAXONOMY never gates")
        let broken = try run(groups, good, floors: floors, failures: ["r2"])
        #expect(!broken.pass && broken.statuses[2].status == "FAIL(input)" && broken.backendErrors.count == 1)
        #expect(!(try run(groups, good, floors: nil).pass), "no baseline, no pass")
        #expect(try run(groups, good, floors: floors, gate: .promote).statuses.map(\.group) == ["hard", "hardsem"])
    }

    @Test("a ratcheted group that finds no images fails, and says so")
    func emptyGroup() throws {
        let groups: [BatterySpec.Group] = [.init(name: "hard", mode: .hard, want: "real", paths: ["a"]), .init(name: "gone", mode: .ratchet, want: "real")]
        let floors: [String: BatteryGroupResult] = ["gone": .init(acc: 0.9, n: 40, mode: .ratchet, want: "real")]
        let report = try run(groups, ["a": Self.v("real")], floors: floors)
        #expect(!report.pass)
        #expect(report.statuses.map(\.status) == ["PASS", "FAIL(no images)"])
    }

    @Test("a rebaseline records this run's floors")
    func rebaseline() throws {
        let groups: [BatterySpec.Group] = [.init(name: "r", mode: .ratchet, want: "real", paths: ["a", "b"])]
        let report = try run(groups, ["a": Self.v("real"), "b": Self.v("generated")], floors: nil, rebaseline: true)
        #expect(report.pass && report.baseline.changed)
    }

    @Test("the input-set hash is Python's json_hash, escapes included")
    func inputSetHash() {
        let rows = [
            BatteryImageRow(path: "/a/b/2.JPG", inputSHA256: String(repeating: "00", count: 32), group: "user_real", want: "real", weightedPred: "real", weightedP: 0.1, semScore: nil, capPresent: false),
            BatteryImageRow(path: "/data/atlas/anchors/art/real/Été \"quoted\" 👍.jpg", inputSHA256: String(repeating: "ab", count: 32),
                            group: "atlas_art_real", want: "real", weightedPred: "real", weightedP: 0.1, semScore: nil, capPresent: false),
        ]
        #expect(BatteryRunner.inputSetHash(rows) == "80fdc1ebfcdb179465b8f2ee9eaf993ff62681761b416a64cba7b77b88f1d2b9")   // Python 3: json.dumps(…, sort_keys=True, separators=(",", ":"))
    }

    @Test("a result JSON reads as the route backend reads it")
    func verdictFromJSON() throws {
        let json = #"{"verdict":{"weighted":{"prediction":"generated","score":0.7},"majority":{"prediction":"real","score":0.1}},"semantic_tiles":[[0.9,0.2],[0.8,0.7]],"capture":{"present":true}}"#
        let v = try BatteryVerdict(resultJSON: Data(json.utf8))
        #expect(v.weighted == "generated" && v.weightedScore == 0.7 && v.semanticScore == 0.75 && v.capturePresent)
        let none = try BatteryVerdict(resultJSON: Data(#"{"verdict":{"weighted":{"prediction":"real","score":0.2}}}"#.utf8))
        #expect(none.semanticScore == nil && !none.capturePresent)
    }
}
