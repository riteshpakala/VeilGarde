//
//  HubDownload.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A Hugging Face checkpoint fetched through FrigateHub into a folder of the caller's
//        choosing (the work area's hf/), for the backbone imports: only the files asked for, and
//        no second copy in a cache under the home folder.
//  PIN:  HubApi(downloadBase:, cache: nil).snapshot(from:matching:) lays files out as
//        <base>/models/<org>/<name>/<file>. The CLI is synchronous, so the download runs as a task
//        the calling thread waits on. A token, when a repository needs one, comes from HF_TOKEN.
//

import Foundation
import Hub
import VeilGardeCore

public enum HubDownload {
    private final class Outcome: @unchecked Sendable {
        var url: URL?
        var error: Error?
    }

    /// The snapshot folder of `repository` holding the files that match `globs`.
    public static func snapshot(_ repository: String, matching globs: [String], into base: URL) throws -> URL {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let api = HubApi(downloadBase: base, cache: nil)
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task {
            do { outcome.url = try await api.snapshot(from: repository, matching: globs) } catch { outcome.error = error }
            done.signal()
        }
        done.wait()
        if let error = outcome.error { throw VeilGardeFailure.data("downloading \(repository) failed: \(error)") }
        guard let url = outcome.url else { throw VeilGardeFailure.internalError("the \(repository) download returned no folder") }
        return url
    }
}
