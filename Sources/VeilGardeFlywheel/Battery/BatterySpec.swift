//
//  BatterySpec.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The battery spec (battery_spec_v2.json) as a value, and how its groups become files:
//        each group names images by explicit path and by glob, filters them by substring, and
//        says what every image in it must read (real or generated) and how strictly.
//  PIN:  The Python battery's resolve_groups, step for step: `{VAR}` substitution from the spec's
//        vars (IMAGES is VEILGARDE_BATTERY_IMAGES, else the work area's battery/images); glob matches
//        sorted, then include_substr and exclude_substr on the full path, then the explicit
//        paths appended; an empty group with skip_if_empty is dropped; the promote gate keeps
//        only HARD and HARD_SEM groups. Globs are Python's: a wildcard only in the last path
//        component here, `*` never matching a leading dot, case-sensitive names, sorted by
//        code point.
//

import Foundation
import VeilGardeCore

public struct BatterySpec: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case hard = "HARD"
        case hardSemantic = "HARD_SEM"
        case ratchet = "RATCHET"
        case ratchetSemantic = "RATCHET_SEM"
        case taxonomy = "TAXONOMY"
        case report = "REPORT"

        public var isHard: Bool { self == .hard || self == .hardSemantic }
    }

    public enum Gate: String, Codable, Sendable, CaseIterable {
        /// HARD and HARD_SEM groups only: what a base promote must pass.
        case promote
        /// Every group: what a head or combiner promote must pass.
        case full
    }

    public struct Group: Codable, Sendable, Equatable {
        public var name: String
        public var mode: Mode
        public var want: String
        public var paths: [String]?
        public var globs: [String]?
        public var includeSubstr: String?
        public var excludeSubstr: String?
        public var skipIfEmpty: Bool?
        public var note: String?

        public init(name: String, mode: Mode, want: String, paths: [String]? = nil, globs: [String]? = nil, includeSubstr: String? = nil,
                    excludeSubstr: String? = nil, skipIfEmpty: Bool? = nil, note: String? = nil) {
            self.name = name
            self.mode = mode
            self.want = want
            self.paths = paths
            self.globs = globs
            self.includeSubstr = includeSubstr
            self.excludeSubstr = excludeSubstr
            self.skipIfEmpty = skipIfEmpty
            self.note = note
        }

        enum CodingKeys: String, CodingKey {
            case name, mode, want, paths, globs, note
            case includeSubstr = "include_substr"
            case excludeSubstr = "exclude_substr"
            case skipIfEmpty = "skip_if_empty"
        }
    }

    public var version: Int
    public var doc: String?
    public var tolerance: Double
    public var baseline: String?
    public var vars: [String: String]
    public var groups: [Group]

    public init(version: Int = 1, tolerance: Double = 0.001, vars: [String: String] = [:], groups: [Group]) {
        self.version = version
        self.tolerance = tolerance
        self.vars = vars
        self.groups = groups
    }

    public static func load(_ url: URL) throws -> BatterySpec {
        do { return try JSONDecoder().decode(BatterySpec.self, from: Data(contentsOf: url)) } catch {
            throw VeilGardeFailure.data("\(url.path) is not a battery spec: \(error)")
        }
    }

    /// The environment variable that names the folder `{IMAGES}` stands for.
    public static let imagesKey = "VEILGARDE_BATTERY_IMAGES"

    /// The spec's vars on this Mac: IMAGES is VEILGARDE_BATTERY_IMAGES when set, else `images`
    /// (the work area's battery/images) when given, else the spec's own default.
    public func resolvedVars(environment: [String: String] = ProcessInfo.processInfo.environment, images: URL? = nil) -> [String: String] {
        var v = vars
        if let named = environment[Self.imagesKey], !named.isEmpty {
            v["IMAGES"] = (named as NSString).expandingTildeInPath
        } else if let images {
            v["IMAGES"] = images.standardizedFileURL.path
        }
        return v
    }

    public struct ResolvedGroup: Sendable, Equatable {
        public var name: String
        public var files: [String]
        public var want: String
        public var mode: Mode
    }

    public func resolve(gate: Gate, vars v: [String: String]) throws -> [ResolvedGroup] {
        var out: [ResolvedGroup] = []
        for g in groups {
            if gate == .promote && !g.mode.isHard { continue }
            var files = try (g.globs ?? []).flatMap { try Self.glob(Self.substitute($0, v)) }.sorted(by: Self.pythonOrder)
            if let include = g.includeSubstr { files = files.filter { $0.contains(include) } }
            if let exclude = g.excludeSubstr { files = files.filter { !$0.contains(exclude) } }
            files += (g.paths ?? []).map { Self.substitute($0, v) }
            if files.isEmpty && g.skipIfEmpty == true { continue }
            out.append(ResolvedGroup(name: g.name, files: files, want: g.want, mode: g.mode))
        }
        return out
    }

    static func substitute(_ pattern: String, _ vars: [String: String]) -> String {
        var s = pattern
        for (key, value) in vars { s = s.replacingOccurrences(of: "{\(key)}", with: value) }
        return s
    }

    static func pythonOrder(_ a: String, _ b: String) -> Bool { a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) }

    /// Python's glob.glob for a pattern whose wildcards sit in its last component.
    static func glob(_ pattern: String) throws -> [String] {
        let url = URL(fileURLWithPath: pattern)
        let directory = url.deletingLastPathComponent().path, name = url.lastPathComponent
        guard !directory.contains("*") && !directory.contains("?") && !directory.contains("[") else {
            throw VeilGardeFailure.usage("battery glob \(pattern): a wildcard outside the last path component is not supported")
        }
        guard name.contains("*") || name.contains("?") || name.contains("[") else {
            return FileManager.default.fileExists(atPath: pattern) ? [pattern] : []
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let prefix = pattern.hasPrefix("/") || !directory.isEmpty ? (directory.hasSuffix("/") ? directory : directory + "/") : ""
        return entries.filter { !$0.hasPrefix(".") && fnmatch($0, name) }.map { prefix + $0 }
    }

    /// fnmatch's `*`, `?` and `[seq]` (`[!seq]`), case-sensitive.
    static func fnmatch(_ name: String, _ pattern: String) -> Bool {
        let n = Array(name.unicodeScalars), p = Array(pattern.unicodeScalars)
        func match(_ i: Int, _ j: Int) -> Bool {
            if j == p.count { return i == n.count }
            switch p[j] {
            case "*":
                var k = i
                while true {
                    if match(k, j + 1) { return true }
                    if k == n.count { return false }
                    k += 1
                }
            case "?":
                return i < n.count && match(i + 1, j + 1)
            case "[":
                guard i < n.count, let close = p[(j + 1)...].firstIndex(of: "]"), close > j + 1 else {
                    return i < n.count && n[i] == "[" && match(i + 1, j + 1)
                }
                var set = Array(p[(j + 1)..<close])
                let negate = set.first == "!"
                if negate { set.removeFirst() }
                var hit = false
                var k = 0
                while k < set.count {
                    if k + 2 < set.count, set[k + 1] == "-" {
                        if set[k].value <= n[i].value && n[i].value <= set[k + 2].value { hit = true }
                        k += 3
                    } else {
                        if set[k] == n[i] { hit = true }
                        k += 1
                    }
                }
                return hit != negate && match(i + 1, close + 1)
            default:
                return i < n.count && n[i] == p[j] && match(i + 1, j + 1)
            }
        }
        return match(0, 0)
    }
}
