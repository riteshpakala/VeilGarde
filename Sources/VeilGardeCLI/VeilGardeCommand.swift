//
//  VeilGardeCommand.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The `veilgarde` root command. Bare `veilgarde` prints help; the subcommands detect
//        (route, batch), extract and train (features, train), migrate the store (store), run the
//        flywheel, measure the
//        detector part by part (research), sign and match watermarks, manage weights and bundles,
//        and check the DINOv2 and CLIP towers against their references (parity).
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
        abstract: "VeilGarde, the AI-generated-image detector: a stack of independent members (the camera head, the screenshot head, the capture signature, the specialist heads, the semantic tiles) and the revisions that read them, the flywheel that grows them, and a crop-robust watermark read off a warp residual.",
        discussion: "Start with `veilgarde doctor`. Every command writes its result to stdout; add --json where offered.",
        version: VeilGardeVersion.string,
        subcommands: [DoctorCommand.self, RouteCommand.self, BatchCommand.self, FeaturesCommand.self,
                      TrainCommand.self, StoreCommand.self, FlywheelCommand.self, ResearchCommand.self, WatermarkCommand.self, WeightsCommand.self, BundleCommand.self, ParityCommand.self]
    )

    func run() async throws {
        print(VeilGardeCommand.helpMessage())
    }
}
