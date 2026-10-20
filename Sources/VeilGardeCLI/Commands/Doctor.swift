//
//  Doctor.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde doctor`: the checks before anything else. The checks live in the VeilGarde
//        umbrella (Doctor), so every layer adds its own; a failed check says what is missing and
//        the command exits 1.
//

import ArgumentParser
import Foundation
import VeilGarde

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Check the setup: Metal library, work area, free space, bundle, weights.")

    @OptionGroup var workArea: WorkAreaOptions

    func run() throws {
        print("veilgarde doctor")
        let options = workArea
        let checks = Doctor.run(area: Result { try options.resolve() })
        for check in checks { print(check.line) }
        let failures = checks.filter { !$0.ok }.count
        print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
        if failures > 0 { throw ArgumentParser.ExitCode(FailureCode.doctor.rawValue) }
    }
}
