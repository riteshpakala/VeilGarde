//
//  VeilGardeCommand.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The `veilgarde` root command. Bare `veilgarde` prints help; the subcommands detect
//        (score, fuse, route, batch), extract and train (features, train), run the flywheel,
//        measure what could be pruned (research), sign and match watermarks, manage weights and
//        bundles, and prove parity with Garde.
//  PIN:  Results go to stdout and progress to stderr, so `veilgarde route x.jpg --json | jq`
//        stays clean. A VeilGardeFailure exits with its sysexits code (Options.swift).
//

import ArgumentParser
import Foundation
import VeilGarde

@main
struct VeilGardeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "veilgarde",
        abstract: "VeilGarde, the AI-generated-image detector: the warp lens, its models, the flywheel that grows them, and a watermark on the same residual.",
        discussion: "Start with `veilgarde doctor`. Every command writes its result to stdout; add --json where offered.",
        version: VeilGardeVersion.string,
        subcommands: [DoctorCommand.self, ScoreCommand.self, FuseCommand.self, RouteCommand.self, BatchCommand.self, FeaturesCommand.self,
                      TrainCommand.self, FlywheelCommand.self, ResearchCommand.self, WatermarkCommand.self, WeightsCommand.self, BundleCommand.self, ParityCommand.self]
    )

    func run() async throws {
        print(VeilGardeCommand.helpMessage())
    }
}
