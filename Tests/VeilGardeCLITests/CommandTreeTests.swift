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
        ["features", "capture", "x.jpg"],
        ["parity", "dino", "f.safetensors", "--images", "dir", "--dino", "xsmall"],
        ["route", "x.jpg", "--json", "--hint", "screenshot", "--semantic-profile", "semantic_removed", "--bundle", "/tmp/b", "--dino", "xxsmall", "--weights-dir", "/tmp/w"],
        ["route", "x.jpg", "--cpu"], ["batch", "in.jsonl", "out.jsonl", "--dino", "small"],
        ["features", "extract", "dir", "--shard", "s1", "--label", "1", "--category", "art", "--source", "civitai", "--store", "/tmp/s", "--limit", "5", "--dino", "small"],
        ["features", "extract", "list.jsonl", "--shard", "s", "--columns", "dino_norm,cap", "--store", "/tmp/aux"],
        ["train", "plan", "--preset", "--store", "/tmp/s", "--parent", "live"], ["train", "plan", "--recipe", "r.toml"],
        ["train", "fusion", "--mode", "scratch", "--trees", "100", "--eta", "0.05", "--new-generator-weight", "2", "--id", "f1", "--replace", "--plan"],
        ["train", "fusion", "--mode", "scratch", "--trees", "1000", "--depth", "7", "--columns", "dino_fusion,dino_norm,cap", "--plan"],
        ["train", "heads", "--kinds", "art,art-pair,preview"], ["train", "combiner", "--reals-weight", "3"], ["train", "combiner", "--reals-weight", "2", "--out-of-fold", "5"],
        ["features", "residual", "--shards", "a,b", "--replace"], ["train", "all"],
        ["train", "run", "recipe.toml", "--work-area", "/tmp/vg"],
        ["flywheel", "init", "--work-area", "/tmp/vg"], ["flywheel", "init", "--battery"],
        ["flywheel", "acquire", "--budget", "60", "--per", "10", "--targets", "test", "--shard", "s", "--no-route", "--dry-run"],
        ["flywheel", "gap", "--shards", "fusion_v197", "--no-write"], ["weights", "import-clip", "--from", "/tmp/model.safetensors", "--out", "/tmp/clip.safetensors"],
        ["parity", "clip", "f.safetensors", "--images", "a.png", "--images", "b.png"], ["flywheel", "seed", "--from", "/data/store"], ["flywheel", "ingest", "items.jsonl", "--shard", "s"],
        ["flywheel", "candidates", "--id", "w1", "--replace", "--plan"], ["flywheel", "agreement", "--bundle", "/tmp/c", "--no-log"],
        ["flywheel", "battery", "--gate", "promote", "--bundle", "/tmp/c", "--json", "-"], ["flywheel", "battery", "--rebaseline", "--yes-i-reviewed"],
        ["flywheel", "promote", "human", "--from", "/tmp/c", "--dry-run"], ["flywheel", "rollback", "20261019T120000Z"], ["flywheel", "status"],
        ["watermark", "sign", "x.jpg", "--json"], ["watermark", "match", "crop.jpg", "vw1:AAAA", "--phases", "0,16", "--json"], ["watermark", "verify", "x.jpg", "sig.txt"],
        ["watermark", "accept", "--n", "20", "--dataset", "/data/fm", "--seed", "3", "--phases", "0,8", "--out", "r.json"],
        ["watermark", "invariance", "--images", "/d", "--images", "list.txt", "--baseline", "b.json", "--out", "o.json"],
        ["weights", "list"], ["weights", "verify", "--weights-dir", "/tmp/w"], ["bundle", "show"], ["bundle", "verify", "/tmp/b"], ["bundle", "diff", "/tmp/a", "/tmp/b"],
        ["weights", "import-dinov2", "--from", "/tmp/model.safetensors", "--variant", "small", "--out", "/tmp/w", "--replace"],
        ["weights", "export-xxsmall", "--from", "/tmp/xs.safetensors", "--out", "/tmp/xx.safetensors"],
        ["research", "census", "a.jpg", "list.txt", "--battery", "--sample", "40", "--final-mixed", "/data/fm", "--json", "-", "--weights-dir", "/tmp/w"],
        ["research", "census", "/d", "--label", "real", "--bundle", "/tmp/b", "--dino", "xsmall", "--semantic-profile", "control"],
        ["research", "compare", "--reference", "a.json", "--variant", "b.json", "--reference-iphone", "c.json", "--variant-iphone", "d.json", "--battery", "r.json", "--judge", "part", "--name", "v"],
    ])
    func invocationParses(arguments: [String]) throws {
        _ = try VeilGardeCommand.parseAsRoot(arguments)
    }
}

@Suite("Retired commands")
struct RetiredCommandTests {
    @Test("the warp's detection commands and the studies are gone", arguments: [
        ["score", "x.jpg"], ["fuse", "x.jpg"], ["parity", "warp", "f.json"], ["features", "show", "x.jpg"], ["features", "tiles", "/d"],
        ["train", "warp", "--dataset", "/d"], ["train", "calibration", "--dataset", "/d"], ["train", "noiseprint"], ["research", "prune"],
        ["research", "core"], ["bundle", "derive", "--from", "shipped", "--id", "v"], ["route", "x.jpg", "--base", "warp"],
    ])
    func retired(arguments: [String]) {
        #expect(throws: (any Error).self) { _ = try VeilGardeCommand.parseAsRoot(arguments) }
    }
}
