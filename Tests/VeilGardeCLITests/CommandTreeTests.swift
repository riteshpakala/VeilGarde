//
//  CommandTreeTests.swift
//  VeilGardeCLITests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The command tree parses: every command path answers --help naming its own path, and a
//        representative full invocation of each command parses to that command with its flags.
//

import ArgumentParser
import Testing
import VeilGarde
@testable import VeilGardeCLI

@Suite("Command tree")
struct CommandTreeTests {
    @Test func rootParses() throws {
        let root = try VeilGardeCommand.parseAsRoot([])
        #expect(root is VeilGardeCommand)
        #expect(VeilGardeCommand.configuration.commandName == "veilgarde")
    }

    @Test func versionIsTheCore() {
        #expect(VeilGardeCommand.configuration.version == VeilGardeVersion.string)
    }

    /// Every command below the root, with its path of names.
    static func commands(_ command: ParsableCommand.Type, prefix: [String] = []) -> [(path: [String], type: ParsableCommand.Type)] {
        command.configuration.subcommands.flatMap { sub -> [(path: [String], type: ParsableCommand.Type)] in
            let name = sub.configuration.commandName ?? String(describing: sub).lowercased()
            return [(prefix + [name], sub)] + commands(sub, prefix: prefix + [name])
        }
    }

    @Test("every command renders its help, naming its own path")
    func everyCommandHasHelp() throws {
        let all = Self.commands(VeilGardeCommand.self)
        #expect(all.count >= 1, "\(all.count) commands")
        for (path, type) in all {
            let help = VeilGardeCommand.helpMessage(for: type)
            #expect(help.contains("USAGE: veilgarde \(path.joined(separator: " "))"), "\(path.joined(separator: " ")): \(help.prefix(120))")
            #expect(type.configuration.abstract.count > 10, "\(path.joined(separator: " ")) has no abstract")
        }
    }

    @Test("a full invocation of each command parses", arguments: [
        ["doctor"], ["doctor", "--work-area", "/tmp/vg"],
        ["score", "x.jpg", "--json", "-", "--patch", "64", "--repeat", "2", "--cpu", "--exact-warp", "--hotspot", "asymmetric",
         "--threshold", "0.5", "--band", "0.05", "--native-check", "--full-res", "--timing", "--dump-features", "f.json", "--no-color"],
        ["features", "capture", "x.jpg"], ["features", "show", "x.jpg", "--tiles", "--json"],
        ["parity", "warp", "fixture.json"], ["parity", "dirsig", "fixture.json"], ["parity", "dino", "f.safetensors", "--images", "dir", "--dino", "xsmall"],
        ["fuse", "x.jpg", "--json", "-", "--dino", "xxsmall"],
        ["route", "x.jpg", "--json", "--hint", "screenshot", "--semantic-profile", "semantic_removed", "--result-surface", "legacy-semantic",
         "--majority-model", "m.json", "--majority-calibration", "c.json", "--render-taxonomy", "--zoom-escalation", "--x-domain-gate", "--bundle", "/tmp/b"],
        ["route", "x.jpg", "--map", "--no-color", "--cpu"], ["batch", "in.jsonl", "out.jsonl", "--dino", "small"],
        ["features", "tiles", "/data/final_mixed", "--sample-per-label", "20", "--seed", "3", "--work-area", "/tmp/vg"],
        ["features", "extract", "dir", "--shard", "s1", "--label", "1", "--category", "art", "--source", "civitai", "--store", "/tmp/s", "--limit", "5", "--dino", "small"],
        ["train", "plan", "--preset", "/data/final_mixed", "--store", "/tmp/s", "--parent", "live"], ["train", "plan", "--recipe", "r.toml"],
        ["train", "warp", "--dataset", "/data/fm", "--shape", "v18", "--sample-per-label", "50", "--trees", "20", "--depth", "4", "--eta", "0.1", "--no-calibration", "--id", "w1", "--replace", "--plan"],
        ["train", "calibration", "--dataset", "/data/fm", "--max-real-fpr", "0.1", "--band", "0.04"],
        ["train", "fusion", "--mode", "scratch", "--trees", "100", "--eta", "0.05", "--new-generator-weight", "2", "--allow-mixed-warp"],
        ["train", "heads", "--kinds", "art,art-pair,preview"], ["train", "combiner", "--reals-weight", "3"], ["train", "all", "--dataset", "/data/fm"],
        ["train", "run", "recipe.toml", "--work-area", "/tmp/vg"],
        ["flywheel", "init", "--work-area", "/tmp/vg"], ["flywheel", "acquire", "--budget", "60", "--per", "10", "--targets", "test", "--shard", "s", "--no-route", "--dry-run"],
        ["flywheel", "gap", "--shards", "fusion_v197", "--no-write"], ["weights", "import-clip", "--from", "/tmp/model.safetensors", "--out", "/tmp/clip.safetensors"],
        ["parity", "clip", "f.safetensors", "--images", "a.png", "--images", "b.png"], ["flywheel", "seed", "--from", "/data/store"], ["flywheel", "ingest", "items.jsonl", "--shard", "s"],
        ["flywheel", "candidates", "--id", "w1", "--allow-mixed-warp", "--replace", "--plan"], ["flywheel", "agreement", "--bundle", "/tmp/c", "--no-log"],
        ["flywheel", "battery", "--gate", "promote", "--bundle", "/tmp/c", "--json", "-"], ["flywheel", "battery", "--rebaseline", "--yes-i-reviewed"],
        ["flywheel", "promote", "human", "--from", "/tmp/c", "--dry-run"], ["flywheel", "rollback", "20261019T120000Z"], ["flywheel", "status"],
        ["watermark", "sign", "x.jpg", "--json"], ["watermark", "match", "crop.jpg", "vw1:AAAA", "--phases", "0,16", "--json"], ["watermark", "verify", "x.jpg", "sig.txt"],
        ["watermark", "accept", "--n", "20", "--dataset", "/data/fm", "--seed", "3", "--phases", "0,8", "--out", "r.json"],
        ["weights", "list"], ["weights", "verify", "--weights-dir", "/tmp/w"], ["bundle", "show"], ["bundle", "verify", "/tmp/b"], ["bundle", "diff", "/tmp/a", "/tmp/b"],
        ["weights", "import-dinov2", "--from", "/tmp/model.safetensors", "--variant", "small", "--out", "/tmp/w", "--replace"],
        ["weights", "export-xxsmall", "--from", "/tmp/xs.safetensors", "--out", "/tmp/xx.safetensors"],
        ["train", "noiseprint", "--epochs", "2", "--per-family", "40", "--seed", "1", "--no-patch-cache", "--plan"], ["features", "patches", "--per-family", "40"],
        ["research", "prune", "--parts", "warp,stack", "--resamples", "100", "--tiles", "/tmp/t", "--store", "/tmp/s", "--no-single-features", "--fusion-trees", "100", "--json", "-"],
        ["research", "census", "a.jpg", "list.txt", "--battery", "--sample", "40", "--final-mixed", "/data/fm", "--json", "-", "--weights-dir", "/tmp/w"],
        ["flywheel", "init", "--battery"],
    ])
    func invocationParses(arguments: [String]) throws {
        _ = try VeilGardeCommand.parseAsRoot(arguments)
    }
}
