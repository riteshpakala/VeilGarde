//
//  Acquirer.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The daily acquisition: collector jobs (a source, the class it fills, its queries) run
//        against the sources, every image fetched into memory, gated, routed, measured into the
//        store's three columns, and dropped. What lands on disk is one new
//        shard of features and each source's cursor; no image is ever written.
//  PIN:  flywheel_scrape.py and atlas_collect.py's engine: per job max(50, budget / jobs) images
//        unless told otherwise; queries are comma-separated and run in order; an item id is
//        query-prefixed (the collectors' sid) and skipped when seen; a keyed source without its key is
//        skipped with the reason (Civitai's key is optional); cursors persist after every page, an
//        exhausted query is not listed again, and 20 empty pages in a row leave a query for the
//        next run.
//        The router files generated images by CLIP and flags NSFW by margin; reals keep their
//        job's category. Rows land in acquire_<date>[_n] with their provenance (source id and
//        URL, licence, native size, dHash, route scores) and the shard records what measured it.
//

import CoreGraphics
import Foundation
import VeilGardeCore
import VeilGardeLens

public struct AcquireJob: Codable, Sendable, Equatable {
    public var source: String
    public var category: String
    public var label: String
    public var query: String
    public var gap: Double?

    public init(source: String, category: String, label: String, query: String, gap: Double? = nil) {
        self.source = source
        self.category = category
        self.label = label
        self.query = query
        self.gap = gap
    }

    public var queries: [String] {
        let q = query.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return q.isEmpty ? [""] : q
    }
}

public struct AcquireTargets: Codable, Sendable {
    public struct Entry: Codable, Sendable { public var domain: String; public var category: String; public var label: Int; public var jobs: [AcquireJob] }
    public var version: Int
    public var defaultJobs: [AcquireJob]
    public var testJobs: [AcquireJob]
    public var targetMap: [Entry]

    enum CodingKeys: String, CodingKey {
        case version
        case defaultJobs = "default_jobs"
        case testJobs = "test_jobs"
        case targetMap = "target_map"
    }

    public static func shipped() throws -> AcquireTargets {
        try JSONDecoder().decode(AcquireTargets.self, from: Data(contentsOf: FlywheelResources.url("acquire_targets_v1.json")))
    }

    public func jobs(domain: String, category: String, label: Int) -> [AcquireJob] {
        targetMap.first { $0.domain == domain && $0.category == category && $0.label == label }?.jobs ?? []
    }
}

public struct AcquireReport: Codable, Sendable {
    public struct Job: Codable, Sendable {
        public var job: AcquireJob
        public var accepted = 0
        public var fetched = 0
        public var rejected: [String: Int] = [:]
        public var skipped: String?
    }
    public var jobs: [Job] = []
    public var shard: String?
    public var rows = 0
    public var seconds = 0.0
}

public final class Acquirer {
    struct State: Codable { var cursors: [String: SourceCursor] = [:]; var seen: [String] = [] }

    /// Consecutive empty pages after which a query is left for the next run.
    public static let stalledPages = 20

    public let area: FlywheelArea
    let transport: HTTPTransport
    let sources: [String: AcquireSource]
    let environment: [String: String]
    let sleep: (TimeInterval) -> Void
    let note: (String) -> Void

    public init(area: FlywheelArea, transport: HTTPTransport = URLSessionTransport(), sources: [AcquireSource] = SourceRegistry.all(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }, note: @escaping (String) -> Void = { _ in }) {
        self.area = area
        self.transport = transport
        self.sources = Dictionary(uniqueKeysWithValues: sources.map { ($0.name, $0) })
        self.environment = environment
        self.sleep = sleep
        self.note = note
    }

    var stateDirectory: URL { area.root.appendingPathComponent("acquire/state", isDirectory: true) }

    func loadState(_ source: String) -> State {
        (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateDirectory.appendingPathComponent("\(source).json")))) ?? State()
    }

    func save(_ state: State, _ source: String) throws {
        var s = state
        if s.seen.count > 200_000 { s.seen = Array(s.seen.suffix(200_000)) }
        try JSONCoding.write(s, to: stateDirectory.appendingPathComponent("\(source).json"))
    }

    /// A new shard name for today: acquire_<yyyyMMdd>, then _b, _c, ….
    public func shardName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        let base = "acquire_\(f.string(from: date))"
        let existing = Set(FeatureStore(directory: area.store).shardNames())
        if !existing.contains(base) { return base }
        for s in "bcdefghijklmnopqrstuvwxyz" where !existing.contains("\(base)_\(s)") { return "\(base)_\(s)" }
        return "\(base)_\(UUID().uuidString.prefix(6))"
    }

    public func run(_ jobs: [AcquireJob], perJob: Int, extractor: FeatureMeasuring, router: CategoryRouter?, shard: String? = nil) throws -> AcquireReport {
        let started = Date()
        var report = AcquireReport()
        let store = FeatureStore(directory: area.store)
        let gate = try AcquireGate(store: store)
        var rows: [FeatureRow] = []
        var columns: [FeatureColumn: [Float]] = Dictionary(uniqueKeysWithValues: FeatureColumn.allCases.map { ($0, [Float]()) })
        LensRuntime.configureGPUMemory()

        for job in jobs {
            var entry = AcquireReport.Job(job: job)
            guard let source = sources[job.source] else {
                entry.skipped = job.source == "flux-local" ? "generated locally by hand (mflux), not by a collector" : "no source named \(job.source)"
                note("acquire: \(job.source): \(entry.skipped!)")
                report.jobs.append(entry); continue
            }
            let key = source.keyEnvironment.flatMap { environment[$0] }.flatMap { $0.isEmpty ? nil : $0 }
            if source.keyRequired && key == nil {
                entry.skipped = "needs \(source.keyEnvironment!) in the environment"
                note("acquire: \(job.source): \(entry.skipped!)")
                report.jobs.append(entry); continue
            }
            let http = HTTPClient(transport: transport, rate: source.rate, sleep: sleep)
            var state = loadState(source.name)
            var seen = Set(state.seen)
            note("acquire: \(job.source) \(job.category)/\(job.label) '\(job.query.prefix(40))' → up to \(perJob)")
            for q in job.queries {
                if state.cursors[q]?["exhausted"] == "1" { continue }
                var cursor: SourceCursor? = state.cursors[q] ?? [:]
                var emptyPages = 0
                while let current = cursor, entry.accepted < perJob {
                    let page = try source.page(query: q, cursor: current, http: http, key: key)
                    emptyPages = page.items.isEmpty ? emptyPages + 1 : 0
                    var consumed = 0
                    for item in page.items where entry.accepted < perJob {
                        consumed += 1
                        let sid = q.isEmpty ? Self.sid(item.id) : "\(q.prefix(12))_\(Self.sid(item.id))"
                        guard !seen.contains(sid) else { continue }
                        seen.insert(sid)
                        state.seen.append(sid)
                        guard let data = item.bytes ?? item.url.flatMap({ http.image($0) }) else { entry.rejected["fetch", default: 0] += 1; continue }
                        entry.fetched += 1
                        let label = item.label ?? job.label
                        let jobCategory = item.category ?? job.category
                        switch gate.check(data, category: jobCategory) {
                        case .rejected(let why):
                            entry.rejected[why, default: 0] += 1
                        case .accepted(let id, let cg, let dhash):
                            let route = try router?.route(cg)
                            let category = label == "generated" ? (route?.category ?? jobCategory) : jobCategory
                            let f = try extractor.extract(cg)
                            rows.append(FeatureRow(id: id, path: "/acquired/\(source.name)/\(sid)", label: label == "generated" ? 1 : 0, category: category,
                                                   source: source.name, nsfw: route?.nsfw ?? false, genFamily: item.meta["baseModel"] ?? item.meta["genFamily"],
                                                   sourceID: sid, sourceURL: item.url?.absoluteString,
                                                   license: item.meta["license"].flatMap { $0.isEmpty ? nil : $0 }, width: cg.width, height: cg.height,
                                                   dhash: String(format: "%016llx", dhash), route: route?.scores))
                            for column in FeatureColumn.allCases { columns[column]! += f.values(column) }
                            gate.admit(id: id, dhash: dhash)
                            entry.accepted += 1
                            if entry.accepted % 25 == 0 { note("acquire: \(job.source) \(entry.accepted)/\(perJob)") }
                        }
                        LensRuntime.releaseMemory()
                    }
                    // A page left part-way (the job filled) is listed again next run, where the
                    // seen ids skip what was taken, as the Python collectors resumed.
                    if consumed < page.items.count {
                        state.cursors[q] = current
                        try save(state, source.name)
                        break
                    }
                    cursor = page.next
                    state.cursors[q] = page.next ?? ["exhausted": "1"]
                    try save(state, source.name)
                    if emptyPages >= Self.stalledPages { note("acquire: \(job.source) '\(q)': \(emptyPages) empty pages in a row, moving on"); break }
                }
            }
            note("acquire: \(job.source) accepted \(entry.accepted), rejected \(entry.rejected)")
            report.jobs.append(entry)
        }
        if !rows.isEmpty {
            let name = shard ?? shardName()
            try FeatureShard(name: name, rows: rows, columns: columns,
                             metadata: extractor.provenance.merging(["acquired": FlywheelArea.stamp(started)]) { _, new in new }).write(to: area.store)
            report.shard = name
            report.rows = rows.count
        }
        report.seconds = Date().timeIntervalSince(started)
        return report
    }

    /// atlas_collect._sid: the id's safe characters, at most 40.
    static func sid(_ id: String) -> String {
        let kept = String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-" }.prefix(40))
        return kept.isEmpty ? String(ContentHash.sha256Hex(id).prefix(12)) : kept
    }
}
