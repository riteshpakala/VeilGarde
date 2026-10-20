//
//  Sources.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Where the flywheel finds images: sixteen sources, each listed one page at a time with a
//        cursor the acquirer persists, so a run resumes where the last one stopped. Museums and
//        Commons give real art and photographs; Flickr, Pexels, Unsplash, Openverse and
//        iNaturalist real photographs; Safebooru human-drawn illustration; Civitai and TPDN
//        generated images; Bluesky's firehose both, routed by hashtag.
//  PIN:  atlas_collect.py's adapters (endpoints, parameters, page limits, client-side filters)
//        with two repairs for APIs that moved since: the Met's paginated v1.1 search, and
//        Commons' file URLs judged by their path's extension (they now end in a query),
//        commons_native.py (random Commons files with a camera Make, JPEG, native ≥ 640 px),
//        inat_wildlife.py (research-grade licensed animal observations, id_above cursor) and
//        bsky_stream.py (Jetstream posts with image embeds, tag routes, the AI guard on reals).
//        Keys come from the environment: RIJKS_KEY, FLICKR_KEY, PEXELS_KEY, UNSPLASH_KEY, and
//        CIVITAI_KEY (optional). Lexica is not ported (its API died behind a paywall).
//

import Foundation
import VeilGardeCore

public struct SourceItem: Sendable, Equatable {
    public var id: String
    public var url: URL?
    public var bytes: Data?
    public var meta: [String: String]
    /// A per-item label and category (Bluesky's tag routes); nil takes the job's.
    public var label: String?
    public var category: String?

    public init(id: String, url: URL? = nil, bytes: Data? = nil, meta: [String: String] = [:], label: String? = nil, category: String? = nil) {
        self.id = id
        self.url = url
        self.bytes = bytes
        self.meta = meta
        self.label = label
        self.category = category
    }
}

/// A source's resumable position, per query: string fields the source alone reads.
public typealias SourceCursor = [String: String]

public protocol AcquireSource: AnyObject {
    var name: String { get }
    /// Requests per second, listing and downloads together.
    var rate: Double { get }
    /// The environment variable holding the source's key; nil for a keyless source.
    var keyEnvironment: String? { get }
    var keyRequired: Bool { get }
    /// One page of items for `query` from `cursor`; the next cursor, or nil when exhausted.
    func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?)
}

extension AcquireSource {
    public var keyEnvironment: String? { nil }
    public var keyRequired: Bool { keyEnvironment != nil }
}

enum JSON {
    static func dict(_ any: Any?) -> [String: Any] { any as? [String: Any] ?? [:] }
    static func array(_ any: Any?) -> [Any] { any as? [Any] ?? [] }
    static func string(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }
    static func int(_ any: Any?) -> Int? { (any as? NSNumber)?.intValue ?? (any as? String).flatMap(Int.init) }
}

// MARK: Museums and Commons

/// The Met's open access: the v1.1 search, paginated (the v1 search that returned every id at
/// once was retired on 2026-10-01), then each object for its primary image.
public final class MetSource: AcquireSource {
    public let name = "met"
    public let rate = 3.0
    public static let pageSize = 20
    public init() {}

    public func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        let offset = Int(cursor["offset"] ?? "0") ?? 0
        let r = JSON.dict(http.json(HTTPClient.url("https://collectionapi.metmuseum.org/public/collection/v1.1/search", [
            ("hasImages", "true"), ("q", query), ("offset", String(offset)), ("limit", String(Self.pageSize))])))
        let ids = JSON.array(r["objectIDs"]).compactMap(JSON.string)
        let total = JSON.int(r["total"]) ?? 0
        guard !ids.isEmpty else { return ([], nil) }
        var items: [SourceItem] = []
        for oid in ids {
            let o = JSON.dict(http.json(URL(string: "https://collectionapi.metmuseum.org/public/collection/v1/objects/\(oid)")!, tries: 2))
            if let s = JSON.string(o["primaryImage"]), !s.isEmpty, let url = URL(string: s) {
                items.append(SourceItem(id: oid, url: url, meta: ["title": String((JSON.string(o["title"]) ?? "").prefix(80)),
                                                                  "license": (o["isPublicDomain"] as? Bool) == true ? "public-domain" : ""]))
            }
        }
        let next = offset + ids.count
        return (items, next < min(total, 8000) ? ["offset": String(next)] : nil)
    }
}

public final class AICSource: AcquireSource {
    public let name = "aic"
    public let rate = 2.0
    public init() {}

    public func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        let page = Int(cursor["page"] ?? "1") ?? 1
        guard page <= 100 else { return ([], nil) }
        let r = JSON.dict(http.json(HTTPClient.url("https://api.artic.edu/api/v1/artworks/search", [
            ("q", query), ("query[term][is_public_domain]", "true"), ("fields", "id,image_id,title,artwork_type_title"),
            ("limit", "100"), ("page", String(page))])))
        let data = JSON.array(r["data"]).map(JSON.dict)
        guard !data.isEmpty else { return ([], nil) }
        let items = data.compactMap { a -> SourceItem? in
            guard let image = JSON.string(a["image_id"]), let id = JSON.string(a["id"]) else { return nil }
            return SourceItem(id: id, url: URL(string: "https://www.artic.edu/iiif/2/\(image)/full/1686,/0/default.jpg"),
                              meta: ["title": String((JSON.string(a["title"]) ?? "").prefix(80)), "license": "public-domain"])
        }
        return (items, ["page": String(page + 1)])
    }
}

public final class RijksSource: AcquireSource {
    public let name = "rijks"
    public let rate = 2.0
    public var keyEnvironment: String? { "RIJKS_KEY" }
    public init() {}

    public func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        let p = Int(cursor["p"] ?? "1") ?? 1
        guard p <= 100, let key else { return ([], nil) }
        let r = JSON.dict(http.json(HTTPClient.url("https://www.rijksmuseum.nl/api/en/collection", [
            ("key", key), ("imgonly", "true"), ("type", query), ("ps", "100"), ("p", String(p))])))
        let arts = JSON.array(r["artObjects"]).map(JSON.dict)
        guard !arts.isEmpty else { return ([], nil) }
        let items = arts.compactMap { a -> SourceItem? in
            guard let s = JSON.string(JSON.dict(a["webImage"])["url"]), let id = JSON.string(a["objectNumber"]) else { return nil }
            return SourceItem(id: id, url: URL(string: s), meta: ["title": String((JSON.string(a["title"]) ?? "").prefix(80))])
        }
        return (items, ["p": String(p + 1)])
    }
}

public final class ClevelandSource: AcquireSource {
    public let name = "cleveland"
    public let rate = 2.0
    public init() {}

    public func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        let skip = Int(cursor["skip"] ?? "0") ?? 0
        let r = JSON.dict(http.json(HTTPClient.url("https://openaccess-api.clevelandart.org/api/artworks/", [
            ("q", query), ("has_image", "1"), ("limit", "100"), ("skip", String(skip))])))
        let data = JSON.array(r["data"]).map(JSON.dict)
        guard !data.isEmpty else { return ([], nil) }
        let items = data.compactMap { a -> SourceItem? in
            let images = JSON.dict(a["images"])
            let best = JSON.dict(images["print"]).isEmpty ? JSON.dict(images["web"]) : JSON.dict(images["print"])
            guard let s = JSON.string(best["url"]), let id = JSON.string(a["id"]) else { return nil }
            return SourceItem(id: id, url: URL(string: s), meta: ["title": String((JSON.string(a["title"]) ?? "").prefix(80)), "license": "cc0"])
        }
        return (items, ["skip": String(skip + 100)])
    }
}

public final class WikimediaSource: AcquireSource {
    public let name = "wikimedia"
    public let rate = 2.0
    public init() {}

    public func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        var params: [(String, String)] = [("action", "query"), ("generator", "categorymembers"), ("gcmtitle", "Category:\(query)"),
                                          ("gcmtype", "file"), ("gcmlimit", "100"), ("prop", "imageinfo"), ("iiprop", "url|size"), ("format", "json")]
        for (k, v) in cursor.sorted(by: { $0.key < $1.key }) { params.append((k, v)) }
        let r = JSON.dict(http.json(HTTPClient.url("https://commons.wikimedia.org/w/api.php", params)))
        let pages = JSON.dict(JSON.dict(r["query"])["pages"])
        var items: [SourceItem] = []
        for key in pages.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
            let p = JSON.dict(pages[key])
            let ii = JSON.dict(JSON.array(p["imageinfo"]).first)
            // Commons' URLs carry a tracking query since 2026: test the path's extension.
            guard let s = JSON.string(ii["url"]), let url = URL(string: s), ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()) else { continue }
            items.append(SourceItem(id: JSON.string(p["pageid"]) ?? key, url: url,
                                    meta: ["w": JSON.string(ii["width"]) ?? "", "h": JSON.string(ii["height"]) ?? ""]))
        }
        let next = JSON.dict(r["continue"]).compactMapValues(JSON.string)
        return (items, next.isEmpty ? nil : next)
    }
}

/// Random Commons files that are camera JPEGs at native size (commons_native.py): real sensors.
public final class WikimediaNativeSource: AcquireSource {
    public let name = "wikimedia-native"
    public let rate = 1.0
    public static let minimumSide = 640
    public static let maximumBytes = 30 * 1024 * 1024
    public init() {}

    public func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        let r = JSON.dict(http.json(HTTPClient.url("https://commons.wikimedia.org/w/api.php", [
            ("action", "query"), ("format", "json"), ("generator", "random"), ("grnnamespace", "6"), ("grnlimit", "20"),
            ("prop", "imageinfo"), ("iiprop", "url|size|mime|commonmetadata")])))
        let pages = JSON.dict(JSON.dict(r["query"])["pages"])
        var items: [SourceItem] = []
        for key in pages.keys.sorted() {
            let p = JSON.dict(pages[key])
            let ii = JSON.dict(JSON.array(p["imageinfo"]).first)
            var metadata: [String: String] = [:]
            for m in JSON.array(ii["commonmetadata"]).map(JSON.dict) { if let n = JSON.string(m["name"]), let v = JSON.string(m["value"]) { metadata[n] = v } }
            guard let make = metadata["Make"], !make.isEmpty, JSON.string(ii["mime"]) == "image/jpeg" else { continue }
            let w = JSON.int(ii["width"]) ?? 0, h = JSON.int(ii["height"]) ?? 0, size = JSON.int(ii["size"]) ?? 0
            guard min(w, h) >= Self.minimumSide, size <= Self.maximumBytes, let s = JSON.string(ii["url"]) else { continue }
            items.append(SourceItem(id: key, url: URL(string: s), meta: ["make": String(make.prefix(40)), "model": String((metadata["Model"] ?? "").prefix(40))]))
        }
        return (items, [:])     // a random generator never runs out
    }
}

// MARK: Photographs

public final class FlickrSource: AcquireSource {
    public let name = "flickr"
    public let rate = 1.0
    public var keyEnvironment: String? { "FLICKR_KEY" }
    public init() {}

    public func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        let page = Int(cursor["page"] ?? "1") ?? 1
        guard page <= 40, let key else { return ([], nil) }
        let r = JSON.dict(http.json(HTTPClient.url("https://api.flickr.com/services/rest/", [
            ("method", "flickr.photos.search"), ("api_key", key), ("text", query), ("license", "1,2,3,4,5,6,9,10"),
            ("extras", "url_o,license"), ("content_type", "1"), ("per_page", "250"), ("page", String(page)),
            ("format", "json"), ("nojsoncallback", "1")])))
        let photos = JSON.array(JSON.dict(r["photos"])["photo"]).map(JSON.dict)
        guard !photos.isEmpty else { return ([], nil) }
        let items = photos.compactMap { p -> SourceItem? in
            guard let s = JSON.string(p["url_o"]), let id = JSON.string(p["id"]) else { return nil }   // original bytes only
            return SourceItem(id: id, url: URL(string: s), meta: ["license": "flickr:\(JSON.string(p["license"]) ?? "")"])
        }
        return (items, ["page": String(page + 1)])
    }
}

public final class PexelsSource: AcquireSource {
    public let name = "pexels"
    public let rate = 0.5
    public var keyEnvironment: String? { "PEXELS_KEY" }
    public init() {}

    public func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        let page = Int(cursor["page"] ?? "1") ?? 1
        guard page <= 40, let key else { return ([], nil) }
        let r = JSON.dict(http.json(HTTPClient.url("https://api.pexels.com/v1/search", [("query", query), ("per_page", "80"), ("page", String(page))]),
                                    headers: ["Authorization": key]))
        let photos = JSON.array(r["photos"]).map(JSON.dict)
        guard !photos.isEmpty else { return ([], nil) }
        let items = photos.compactMap { p -> SourceItem? in
            guard let s = JSON.string(JSON.dict(p["src"])["original"]), let id = JSON.string(p["id"]) else { return nil }
            return SourceItem(id: id, url: URL(string: s), meta: ["license": "pexels"])
        }
        return (items, ["page": String(page + 1)])
    }
}

public final class UnsplashSource: AcquireSource {
    public let name = "unsplash"
    public let rate = 0.012        // the demo tier's 50 requests an hour
    public var keyEnvironment: String? { "UNSPLASH_KEY" }
    public init() {}

    public func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        let page = Int(cursor["page"] ?? "1") ?? 1
        guard page <= 20, let key else { return ([], nil) }
        let auth = ["Authorization": "Client-ID \(key)"]
        let r = JSON.dict(http.json(HTTPClient.url("https://api.unsplash.com/search/photos", [("query", query), ("per_page", "30"), ("page", String(page))]), headers: auth))
        let results = JSON.array(r["results"]).map(JSON.dict)
        guard !results.isEmpty else { return ([], nil) }
        var items: [SourceItem] = []
        for p in results {
            // The API guidelines ask for a ping of the download endpoint.
            if let ping = JSON.string(JSON.dict(p["links"])["download_location"]).flatMap(URL.init(string:)) { _ = http.json(ping, headers: auth, tries: 1) }
            if let s = JSON.string(JSON.dict(p["urls"])["full"]), let id = JSON.string(p["id"]) {
                items.append(SourceItem(id: id, url: URL(string: s), meta: ["license": "unsplash"]))
            }
        }
        return (items, ["page": String(page + 1)])
    }
}

public final class OpenverseSource: AcquireSource {
    public let name = "openverse"
    public let rate = 0.05         // under the anonymous tier's daily listing budget
    public init() {}

    public func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        let page = Int(cursor["page"] ?? "1") ?? 1
        guard page <= 12 else { return ([], nil) }
        let r = JSON.dict(http.json(HTTPClient.url("https://api.openverse.org/v1/images/", [("q", query), ("page_size", "20"), ("page", String(page))])))
        let results = JSON.array(r["results"]).map(JSON.dict)
        guard !results.isEmpty else { return ([], nil) }
        let items = results.compactMap { it -> SourceItem? in
            guard let s = JSON.string(it["url"]), let id = JSON.string(it["id"]) else { return nil }
            return SourceItem(id: id, url: URL(string: s), meta: ["license": JSON.string(it["license"]) ?? "", "origin": JSON.string(it["source"]) ?? ""])
        }
        return (items, ["page": String(page + 1)])
    }
}

public final class INaturalistSource: AcquireSource {
    public let name = "inat"
    public let rate = 0.6
    static let iconic = "Aves,Mammalia,Reptilia,Amphibia,Actinopterygii,Insecta,Arachnida,Mollusca"
    static let licenses = "cc0,cc-by,cc-by-nc,cc-by-sa,cc-by-nc-sa"
    public init() {}

    public func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        let above = Int(cursor["id_above"] ?? "300000000") ?? 300_000_000
        let r = JSON.dict(http.json(HTTPClient.url("https://api.inaturalist.org/v1/observations", [
            ("quality_grade", "research"), ("photos", "true"), ("iconic_taxa", Self.iconic), ("photo_license", Self.licenses),
            ("per_page", "200"), ("order", "asc"), ("order_by", "id"), ("id_above", String(above))])))
        let observations = JSON.array(r["results"]).map(JSON.dict)
        guard !observations.isEmpty else { return ([], nil) }
        var last = above
        var items: [SourceItem] = []
        for o in observations {
            last = max(last, JSON.int(o["id"]) ?? last)
            for ph in JSON.array(o["photos"]).prefix(2).map(JSON.dict) {
                guard let pid = JSON.string(ph["id"]), let s = JSON.string(ph["url"]) else { continue }
                let original = s.replacingOccurrences(of: "/square.", with: "/original.")
                items.append(SourceItem(id: pid, url: URL(string: original), meta: ["license": JSON.string(ph["license_code"]) ?? ""]))
            }
        }
        return (items, ["id_above": String(last)])
    }
}

// MARK: Illustration and generated images

public final class SafebooruSource: AcquireSource {
    public let name = "safebooru"
    public let rate = 1.0
    public init() {}

    public func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        let pid = Int(cursor["pid"] ?? "0") ?? 0
        guard pid <= 200 else { return ([], nil) }
        let posts = JSON.array(http.json(HTTPClient.url("https://safebooru.org/index.php", [
            ("page", "dapi"), ("s", "post"), ("q", "index"), ("json", "1"), ("limit", "100"), ("tags", query), ("pid", String(pid))]))).map(JSON.dict)
        guard !posts.isEmpty else { return ([], nil) }
        let items = posts.compactMap { it -> SourceItem? in
            guard let s = JSON.string(it["file_url"]), [".jpg", ".jpeg", ".png"].contains(where: { s.lowercased().hasSuffix($0) }),
                  min(JSON.int(it["width"]) ?? 0, JSON.int(it["height"]) ?? 0) >= 512, let id = JSON.string(it["id"]) else { return nil }
            return SourceItem(id: id, url: URL(string: s))
        }
        return (items, ["pid": String(pid + 1)])
    }
}

/// Civitai's images API: SFW only (server nsfw None and the item's own level), cursor paging.
public final class CivitaiSource: AcquireSource {
    public let name = "civitai"
    public let rate = 1.0
    public var keyEnvironment: String? { "CIVITAI_KEY" }
    public var keyRequired: Bool { false }
    public init() {}

    static func sfw(_ it: [String: Any]) -> Bool {
        let level = (JSON.string(it["nsfwLevel"]) ?? "").lowercased()
        return (it["nsfw"] as? Bool) != true && ["", "none", "1", "0"].contains(level)
    }

    static func item(_ it: [String: Any], extra: [String: String] = [:]) -> SourceItem? {
        guard sfw(it), let s = JSON.string(it["url"]), let id = JSON.string(it["id"]) else { return nil }
        var meta = extra
        if let model = JSON.string(it["baseModel"]) { meta["baseModel"] = model }
        return SourceItem(id: id, url: URL(string: s), meta: meta)
    }

    public func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        var params: [(String, String)] = [("limit", "100"), ("nsfw", "None"), ("sort", query.isEmpty ? "Most Reactions" : query), ("period", "Month")]
        if let c = cursor["cursor"] { params.append(("cursor", c)) }
        let r = JSON.dict(http.json(HTTPClient.url("https://civitai.com/api/v1/images", params), headers: key.map { ["Authorization": "Bearer \($0)"] } ?? [:]))
        let items = JSON.array(r["items"]).map(JSON.dict)
        guard !items.isEmpty else { return ([], nil) }
        let next = JSON.string(JSON.dict(r["metadata"])["nextCursor"])
        return (items.compactMap { Self.item($0) }, next.map { ["cursor": $0] })
    }
}

/// Civitai images from photorealistic-tagged checkpoints (atlas_collect.CivitaiPR): human_gen-rich.
public final class CivitaiByModelSource: AcquireSource {
    public let name = "civitaipr"
    public let rate = 1.0
    public var keyEnvironment: String? { "CIVITAI_KEY" }
    public var keyRequired: Bool { false }
    public init() {}

    public func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        let headers = key.map { ["Authorization": "Bearer \($0)"] } ?? [:]
        var c = cursor
        if c["versions"] == nil {
            let r = JSON.dict(http.json(HTTPClient.url("https://civitai.com/api/v1/models", [
                ("tag", query.isEmpty ? "photorealistic" : query), ("sort", "Highest Rated"), ("limit", "40"), ("nsfw", "false")]), headers: headers))
            c["versions"] = JSON.array(r["items"]).map(JSON.dict).compactMap { m in JSON.array(m["modelVersions"]).first.flatMap { JSON.string(JSON.dict($0)["id"]) } }.joined(separator: ",")
            c["vpos"] = "0"
        }
        let versions = c["versions"]!.split(separator: ",").map(String.init)
        var vpos = Int(c["vpos"] ?? "0") ?? 0
        guard vpos < versions.count else { return ([], nil) }
        var params: [(String, String)] = [("limit", "100"), ("nsfw", "None"), ("modelVersionId", versions[vpos])]
        if let cur = c["cursor"] { params.append(("cursor", cur)) }
        let r = JSON.dict(http.json(HTTPClient.url("https://civitai.com/api/v1/images", params), headers: headers))
        let items = JSON.array(r["items"]).map(JSON.dict).compactMap { CivitaiSource.item($0, extra: ["modelVersion": versions[vpos]]) }
        if let next = JSON.string(JSON.dict(r["metadata"])["nextCursor"]), !JSON.array(r["items"]).isEmpty {
            c["cursor"] = next
        } else {
            c["cursor"] = nil
            vpos += 1
        }
        c["vpos"] = String(vpos)
        return (items, vpos < versions.count ? c : nil)
    }
}

/// thispersondoesnotexist.com: a fresh StyleGAN2 face per request, bytes direct.
public final class TPDNSource: AcquireSource {
    public let name = "tpdn"
    public let rate = 0.5
    public init() {}

    public func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        guard let bytes = http.image(URL(string: "https://thispersondoesnotexist.com/random-person.jpeg")!, headers: ["Cache-Control": "no-cache"]) else {
            return ([], cursor)
        }
        return ([SourceItem(id: String(ContentHash.sha256Hex(bytes).prefix(16)), bytes: bytes, meta: ["genFamily": "stylegan2"])], cursor)
    }
}

/// Every source by name.
public enum SourceRegistry {
    public static func all() -> [AcquireSource] {
        [MetSource(), AICSource(), RijksSource(), ClevelandSource(), WikimediaSource(), WikimediaNativeSource(), FlickrSource(), PexelsSource(),
         UnsplashSource(), OpenverseSource(), INaturalistSource(), SafebooruSource(), CivitaiSource(), CivitaiByModelSource(), TPDNSource(),
         BlueskySource()]
    }

    public static func source(_ name: String) -> AcquireSource? { all().first { $0.name == name } }
}
