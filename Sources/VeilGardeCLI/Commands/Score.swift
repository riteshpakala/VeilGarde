//
//  Score.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde score <image>`: the warp lens alone, the camera-sensor score included. Prints
//        the patch map and both verdicts, or the schema-v2 JSON with --json (a path, or - for
//        stdout only). Replaces `garde <image>`, Garde's headless run.
//  PIN:  The same pipeline Garde's main mode ran (runInferenceFast), so `--json -` here and there
//        differ only in times_sec and the sensor fields the two cuts changed (ResultJSON.changedSinceGarde).
//

import ArgumentParser
import Foundation
import VeilGarde

struct ScoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "score", abstract: "Score an image with the warp lens: the camera-sensor score and the weighted verdict.")

    @Argument(help: "The image (JPEG, PNG, HEIC, WebP…).")
    var image: String
    @OptionGroup var detection: DetectionOptions
    @Option(help: "Write the schema-v2 JSON to this path, or - for stdout only.")
    var json: String?
    @Option(help: "Run the inference this many times (run 1 includes Metal warmup).")
    var `repeat`: Int = 1
    @Option(name: .customLong("dump-features"), help: "Write the tile feature matrix (Garde's --dump-features format) to this path.")
    var dumpFeatures: String?
    @Flag(name: .customLong("no-color"), help: "No terminal colours.")
    var noColor = false

    func run() throws {
        guarded {
            var config = try detection.config()
            config.featureDumpURL = dumpFeatures.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let cg = try loadImage(image)
            var times = [Double]()
            var result: InferenceResult?
            try LensRuntime.withDevice(cpu: detection.cpu) {
                for _ in 0..<max(1, self.repeat) {
                    let (r, seconds) = try timed { try WarpInference.run(cgImage: cg, config: config) }
                    result = r
                    times.append(seconds)
                }
            }
            guard let r = result else { throw VeilGardeFailure.internalError("no result") }
            let device = LensRuntime.deviceName(cpu: detection.cpu)
            if let json {
                try emitJSON(try ResultJSON.encode(r, times: times, device: device), to: json)
                if json == "-" { return }
            }
            let color = !noColor && isatty(STDOUT_FILENO) == 1
            print(PatchMap.render(r, imagePath: image, model: config.modelURL.lastPathComponent, times: times, device: device, color: color), terminator: "")
        }
    }
}
