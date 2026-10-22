//
//  HeadRegistry.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The linear heads and the stack combiner of a bundle, each read once per file and shared.
//        A head the bundle does not name is nil, and the member it powers has nothing to say.
//  PIN:  The reference's head and combiner caches, keyed by the artifact's path so two
//        bundles in one process (the live bundle and a candidate under the battery) never mix,
//        and by the file's modification date and size, so a file the flywheel rewrites in place
//        (a promote, a restore) is read again.
//

import Foundation

public final class HeadRegistry: @unchecked Sendable {
    public static let shared = HeadRegistry()
    private let lock = NSLock()
    private var heads: [String: (FileStamp, LinearHead?)] = [:]
    private var combiners: [String: (FileStamp, StackCombiner?)] = [:]

    public func head(_ kind: HeadKind, in bundle: DetectorBundle) -> LinearHead? {
        guard let url = bundle.url(.head, head: kind) else { return nil }
        return cached(&heads, url) { try? LinearHead.load($0) }
    }

    public func combiner(in bundle: DetectorBundle) -> StackCombiner? {
        guard let url = bundle.url(.combiner) else { return nil }
        return cached(&combiners, url) { try? StackCombiner.load($0) }
    }

    private func cached<T>(_ store: inout [String: (FileStamp, T?)], _ url: URL, _ load: (URL) -> T?) -> T? {
        let key = url.standardizedFileURL.path
        let stamp = FileStamp(path: key)
        lock.lock()
        defer { lock.unlock() }
        if let hit = store[key], hit.0 == stamp { return hit.1 }
        let value = load(url)
        store[key] = (stamp, value)
        return value
    }
}
