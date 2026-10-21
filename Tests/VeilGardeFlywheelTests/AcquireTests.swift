//
//  AcquireTests.swift
//  VeilGardeFlywheelTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Acquisition without the network: the router on Hugging Face's own embeddings, Bluesky's
//        tag routes and event parsing, each source against canned API responses, the collectors' retry
//        rule, the gate's structural and dedup checks, the acquirer end to end (rows written,
//        no image on disk, cursors resumed), and the gap miner's ranking and jobs.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import VeilGardeCore
import VeilGardeLens
@testable import VeilGardeFlywheel

/// Canned responses by URL prefix; records every request.
final class StubTransport: HTTPTransport {
    var routes: [(prefix: String, responses: [HTTPResponse])] = []
    var requests: [URL] = []

    func on(_ prefix: String, _ responses: HTTPResponse...) { routes.append((prefix, responses)) }
    func json(_ prefix: String, _ object: Any) { on(prefix, HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: try! JSONSerialization.data(withJSONObject: object))) }

    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) throws -> HTTPResponse {
        requests.append(url)
        guard let i = routes.firstIndex(where: { url.absoluteString.hasPrefix($0.prefix) }) else { return HTTPResponse(status: 404, body: Data()) }
        let r = routes[i].responses.first!
        if routes[i].responses.count > 1 { routes[i].responses.removeFirst() }
        return r
    }
}

/// A noisy PNG large enough to pass the gate.
func noisePNG(_ w: Int, _ h: Int, seed: UInt64) -> Data {
    var rng = SplitMix64(seed: seed)
    var px = [UInt8](repeating: 255, count: w * h * 4)
    for i in 0..<(w * h) { px[i * 4] = UInt8(rng.next() & 0xFF); px[i * 4 + 1] = UInt8(rng.next() & 0xFF); px[i * 4 + 2] = UInt8(rng.next() & 0xFF) }
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

/// Smooth structure under a little noise: a picture whose difference hash survives a resize.
func patternPNG(_ w: Int, _ h: Int, seed: UInt64) -> (data: Data, image: CGImage) {
    var rng = SplitMix64(seed: seed)
    var px = [UInt8](repeating: 255, count: w * h * 4)
    let cx = Double(w) * (0.3 + 0.4 * rng.unit()), cy = Double(h) * (0.3 + 0.4 * rng.unit())
    for y in 0..<h {
        for x in 0..<w {
            let d = ((Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)).squareRoot()
            let v = 127 + 100 * sin(d / 40) * cos(Double(x) / 90)
            let i = (y * w + x) * 4
            px[i] = UInt8(max(0, min(255, v + Double(rng.next() % 9))))
            px[i + 1] = UInt8(max(0, min(255, 255 - v + Double(rng.next() % 9))))
            px[i + 2] = UInt8(max(0, min(255, Double(x * 255 / w))))
        }
    }
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = ctx.makeImage()!
    return (encodePNG(image), image)
}

func encodePNG(_ image: CGImage) -> Data {
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

/// Constant features: the acquirer's bookkeeping without DINOv2.
final class StubMeasure: FeatureMeasuring {
    let provenance = ["dino_variant": "small"]
    func extract(_ cg: CGImage) throws -> ExtractedFeatures {
        ExtractedFeatures(dinoNorm: [Float](repeating: 0.1, count: 384), dinoFusion: [Float](repeating: 0.2, count: 384), cap: [Float](repeating: 0, count: 9),
                          width: cg.width, height: cg.height)
    }
}

/// A source whose items point at /img/<n>.png on a stub host.
final class FakeSource: AcquireSource {
    let name = "fake"
    let rate = 1000.0
    let total: Int
    init(total: Int) { self.total = total }
    func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        let start = Int(cursor["n"] ?? "0") ?? 0
        let end = min(total, start + 4)
        let items = (start..<end).map { SourceItem(id: "item\($0)", url: URL(string: "https://img.test/img/\($0).png"), meta: ["license": "cc0"]) }
        return (items, end < total ? ["n": String(end)] : nil)
    }
}

@Suite("Acquisition")
struct AcquireTests {
    @Test("the router's category and NSFW margin equal Hugging Face's on its own embeddings")
    func router() throws {
        let router = try CategoryRouter()
        let f = try SafetensorsFile(url: Fixture.repoRoot.appendingPathComponent("Tests/VeilGardeLensTests/Fixtures/clip_parity.safetensors"))
        let e = try f.float32("embeds"), logits = try f.float32("logits")
        for i in 0..<(e.count / 512) {
            let r = router.route(embedding: Array(e[(i * 512)..<((i + 1) * 512)]))
            let l = Array(logits[(i * 13)..<((i + 1) * 13)])
            for k in 0..<5 { #expect(abs(r.scores[k] - l[k]) < 1e-3) }
            #expect(r.top == CategoryRouter.categories[l[0..<5].firstIndex(of: l[0..<5].max()!)!])
            #expect(abs(r.nsfwMargin - (l[5..<10].max()! - l[10..<13].max()!)) < 1e-3)
            #expect(r.category == (["human", "blur", "cgi"].contains(r.top) ? r.top : "art"))
        }
    }

    @Test("Bluesky's routes, its AI guard and its events")
    func bluesky() throws {
        #expect(BlueskySource.route("sunset #midjourney")! == ("art", "generated"))
        #expect(BlueskySource.route("night drive #LongExposure")! == ("blur", "real"))
        #expect(BlueskySource.route("#portraitphotography made with #aiart") == nil || BlueskySource.route("#portraitphotography made with #aiart")! == ("art", "generated"))
        #expect(BlueskySource.route("#streetphotography but AI-generated") == nil, "a real tag beside an AI mention is skipped")
        #expect(BlueskySource.route("lunch") == nil)
        let event: [String: Any] = ["did": "did:plc:abc", "commit": ["operation": "create", "record": [
            "$type": "app.bsky.feed.post", "text": "harbour at dawn", "tags": ["streetphotography"],
            "embed": ["$type": "app.bsky.embed.images", "images": [["image": ["ref": ["$link": "bafkreicid0123456789012345678"]]], ["image": ["ref": ["$link": "bafkreiother"]]], ["image": ["ref": ["$link": "bafkreithird"]]]]]]]]
        let items = BlueskySource.items(event: event)
        try #require(items.count == 2, "an outline tag routes the post")
        #expect(items[0].url?.absoluteString == "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:abc/bafkreicid0123456789012345678@jpeg")
        #expect(items[0].label == "real" && items[0].category == "photo" && items[0].id == "bafkreicid01234567890123_0", "the collectors' id: the cid's first 24 characters")
    }

    @Test("sources read their APIs as the Python adapters do")
    func sources() throws {
        let t = StubTransport()
        let http = HTTPClient(transport: t, rate: 1000, sleep: { _ in })
        t.json("https://collectionapi.metmuseum.org/public/collection/v1.1/search", ["total": 2, "objectIDs": [11, 12]])
        t.json("https://collectionapi.metmuseum.org/public/collection/v1/objects/11", ["primaryImage": "https://images.met/11.jpg", "title": "Wheat Field", "isPublicDomain": true])
        t.json("https://collectionapi.metmuseum.org/public/collection/v1/objects/12", ["primaryImage": ""])
        let met = try MetSource().page(query: "painting", cursor: [:], http: http, key: nil)
        #expect(met.items.map(\.id) == ["11"] && met.items[0].meta["license"] == "public-domain" && met.next == nil)

        t.json("https://commons.wikimedia.org/w/api.php", ["query": ["pages": ["7": ["pageid": 7, "imageinfo": [["url": "https://upload/a.JPG?utm_source=commons.wikimedia.org&utm_content=original", "width": 4000, "height": 3000]]],
                                                                                "8": ["pageid": 8, "imageinfo": [["url": "https://upload/b.svg"]]]]],
                                                           "continue": ["gcmcontinue": "file|B", "continue": "gcmcontinue||"]])
        let wiki = try WikimediaSource().page(query: "Quality_images", cursor: [:], http: http, key: nil)
        #expect(wiki.items.map(\.id) == ["7"] && wiki.next?["gcmcontinue"] == "file|B")

        t.json("https://civitai.com/api/v1/images", ["items": [["id": 1, "url": "https://c/1.jpeg", "nsfwLevel": 1, "baseModel": "Flux.1 D"],
                                                              ["id": 2, "url": "https://c/2.jpeg", "nsfwLevel": "X"], ["id": 3, "url": "https://c/3.jpeg", "nsfw": true]],
                                                    "metadata": ["nextCursor": "abc"]])
        let civ = try CivitaiSource().page(query: "Newest", cursor: [:], http: http, key: nil)
        #expect(civ.items.map(\.id) == ["1"] && civ.items[0].meta["baseModel"] == "Flux.1 D" && civ.next == ["cursor": "abc"])

        t.json("https://safebooru.org/index.php", [["id": 5, "file_url": "https://s/5.png", "width": 800, "height": 600], ["id": 6, "file_url": "https://s/6.png", "width": 400, "height": 900]])
        #expect(try SafebooruSource().page(query: "scenery", cursor: [:], http: http, key: nil).items.map(\.id) == ["5"])

        t.json("https://api.inaturalist.org/v1/observations", ["results": [["id": 300_000_010, "photos": [["id": 77, "url": "https://inat/photos/77/square.jpg", "license_code": "cc-by"]]]]])
        let inat = try INaturalistSource().page(query: "", cursor: [:], http: http, key: nil)
        #expect(inat.items[0].url?.absoluteString == "https://inat/photos/77/original.jpg" && inat.next == ["id_above": "300000010"])

        #expect(SourceRegistry.all().count == 16)
        #expect(SourceRegistry.source("flickr")?.keyRequired == true && SourceRegistry.source("civitai")?.keyRequired == false)
    }

    @Test("a listing call retries 429 and 5xx with 8·2ⁿ s backoff; a download keeps only images ≥ 20 KB")
    func retries() throws {
        let t = StubTransport()
        var slept: [TimeInterval] = []
        let http = HTTPClient(transport: t, rate: 1000, sleep: { if $0 >= 1 { slept.append($0) } })
        t.on("https://api.test/list", HTTPResponse(status: 429, body: Data()), HTTPResponse(status: 503, body: Data()), HTTPResponse(status: 200, body: Data("{\"ok\":1}".utf8)))
        #expect((http.json(URL(string: "https://api.test/list")!) as? [String: Any])?["ok"] as? Int == 1)
        #expect(slept == [8, 16])
        t.on("https://img.test/small.png", HTTPResponse(status: 200, headers: ["Content-Type": "image/png"], body: Data(count: 1000)))
        t.on("https://img.test/page.html", HTTPResponse(status: 200, headers: ["Content-Type": "text/html"], body: Data(count: 50_000)))
        t.on("https://img.test/big.png", HTTPResponse(status: 200, headers: ["Content-Type": "image/png; charset=binary"], body: Data(count: 50_000)))
        #expect(http.image(URL(string: "https://img.test/small.png")!) == nil)
        #expect(http.image(URL(string: "https://img.test/page.html")!) == nil)
        #expect(http.image(URL(string: "https://img.test/big.png")!)?.count == 50_000)
    }

    @Test("the gate: tiny, undecodable, small, duplicate and near-duplicate images are refused")
    func gate() throws {
        let gate = AcquireGate()
        #expect(gate.check(Data(count: 100), category: "art").reason == "tiny")
        #expect(gate.check(Data(repeating: 7, count: 30_000), category: "art").reason == "decode")
        #expect(gate.check(noisePNG(600, 400, seed: 1), category: "art").reason == "min_side")
        let (a, picture) = patternPNG(600, 600, seed: 2)
        guard case .accepted(let id, let cg, let h) = gate.check(a, category: "art") else { Issue.record("not accepted"); return }
        #expect(id == ContentHash.sha1Hex(a) && cg.width == 600)
        gate.admit(id: id, dhash: h)
        #expect(gate.check(a, category: "art").reason == "dup")
        // The same picture, re-encoded at another size: a near copy.
        let ctx = CGContext(data: nil, width: 700, height: 700, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(picture, in: CGRect(x: 0, y: 0, width: 700, height: 700))
        let resized = encodePNG(ctx.makeImage()!)
        #expect((AcquireGate.dhash(try ImageDecoding.cgImage(data: resized)) ^ h).nonzeroBitCount <= 4)
        #expect(gate.check(resized, category: "art").reason == "near_dup")
        #expect(gate.check(noisePNG(600, 600, seed: 3), category: "art").reason == nil)
    }

    @Test("the acquirer keeps features, never images, and resumes its cursors")
    func acquirer() throws {
        let f = try FlywheelFixture()
        let t = StubTransport()
        for n in 0..<10 where n != 3 { t.on("https://img.test/img/\(n).png", HTTPResponse(status: 200, headers: ["Content-Type": "image/png"], body: noisePNG(640, 520, seed: 100 + UInt64(n)))) }
        t.on("https://img.test/img/3.png", HTTPResponse(status: 200, headers: ["Content-Type": "image/png"], body: noisePNG(640, 300, seed: 9)))   // too small
        let acquirer = Acquirer(area: f.area, transport: t, sources: [FakeSource(total: 10)], environment: [:], sleep: { _ in })
        let job = AcquireJob(source: "fake", category: "art", label: "generated", query: "")
        let report = try acquirer.run([job, AcquireJob(source: "flux-local", category: "human", label: "generated", query: "")], perJob: 6,
                                      extractor: StubMeasure(), router: nil, shard: "acquire_test")
        #expect(report.rows == 6 && report.shard == "acquire_test")
        #expect(report.jobs[0].rejected["min_side"] == 1)
        #expect(report.jobs[1].skipped?.contains("by hand") == true)
        let shard = try FeatureShard.read("acquire_test", in: f.area.store)
        #expect(shard.rows.allSatisfy { $0.label == 1 && $0.category == "art" && $0.path.hasPrefix("/acquired/fake/") && $0.license == "cc0" && $0.dhash?.count == 16 })
        #expect(shard.metadata["dino_variant"] == "small" && shard.metadata["acquired"] != nil && shard.columns[.dinoNorm]?.count == 6 * 384)
        // No image anywhere in the work area.
        let walker = FileManager.default.enumerator(at: f.area.root, includingPropertiesForKeys: nil)!
        let images = walker.compactMap { $0 as? URL }.filter { ["png", "jpg", "jpeg", "webp"].contains($0.pathExtension.lowercased()) }
        #expect(images.isEmpty, "\(images)")
        // A second run picks up after the seen items and the stored ids.
        let second = try acquirer.run([job], perJob: 6, extractor: StubMeasure(), router: nil, shard: "acquire_test_b")
        #expect(second.rows == 3, "items 7, 8 and 9 remain (3 was too small)")
        let third = try acquirer.run([job], perJob: 6, extractor: StubMeasure(), router: nil, shard: "acquire_test_c")
        #expect(third.rows == 0 && third.shard == nil)
    }

    @Test("the gap miner ranks buckets by error plus disagreement and maps the worst to jobs")
    func gap() throws {
        let f = try FlywheelFixture()
        var rng = SplitMix64(seed: 5)
        func gauss() -> Float { Float((-2 * log(max(1e-12, rng.unit()))).squareRoot() * cos(2 * .pi * rng.unit())) }
        var rows: [FeatureRow] = []
        var columns: [FeatureColumn: [Float]] = Dictionary(uniqueKeysWithValues: FeatureColumn.allCases.map { ($0, [Float]()) })
        for (k, (path, category, label)) in [("/data/atlas/photo/generated", "photo", 1), ("/data/atlas/art/real", "art", 0), ("/x/final_mixed/real", "v197", 0)].enumerated() {
            for i in 0..<40 {
                rows.append(FeatureRow(id: "g\(k)-\(i)", path: "\(path)/\(i).jpg", label: label, category: category, source: "t"))
                columns[.dinoNorm]! += (0..<384).map { _ in gauss() }
                columns[.dinoFusion]! += (0..<384).map { _ in gauss() }
                columns[.cap]! += [10, 1, 0, 2000, 5, 0.5, 0.5, 0.5, 0]
            }
        }
        let dir = f.root.appendingPathComponent("gapstore", isDirectory: true)
        try FeatureShard(name: "g", rows: rows, columns: columns).write(to: dir)
        let report = try GapMiner.mine(try f.area.liveBundle(), store: FeatureStore(directory: dir), targets: try AcquireTargets.shipped())
        #expect(Set(report.buckets.map(\.name)) == ["processed/photo/gen", "processed/art/real", "camera/photo/real"])
        #expect(report.buckets.map(\.gap) == report.buckets.map(\.gap).sorted(by: >))
        for b in report.buckets { #expect(abs(b.gap - b.baseError - b.disagreement) < 1e-12 && b.n == 40) }
        let expected = report.buckets.filter { $0.gap >= 0.05 }.flatMap { b in (try! AcquireTargets.shipped()).jobs(domain: b.domain, category: b.category, label: b.label) }
        #expect(report.jobs.count <= expected.count && report.jobs.allSatisfy { j in expected.contains { $0.source == j.source && $0.query == j.query } })
        #expect(GapMiner.category(FeatureRow(id: "x", path: "/x/final_mixed/real/a.jpg", label: 0, category: "v197", source: nil)) == "photo")
        #expect(GapMiner.domain(FeatureRow(id: "x", path: "/acquired/met/1", label: 0, category: "art", source: "met")) == "processed")
    }
}
