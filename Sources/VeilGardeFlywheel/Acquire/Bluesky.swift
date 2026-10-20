//
//  Bluesky.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Bluesky through its public Jetstream firehose: posts with image embeds whose text or
//        tags match a route (AI-art tags → generated; bokeh and long-exposure tags → blur reals;
//        portrait tags → human reals; render and game-screenshot tags → cgi reals; genre
//        photography tags → photo reals), each image fetched from the CDN's full-size render.
//  PIN:  bsky_stream.py verbatim: first matching route wins with the AI tags checked first; a
//        real-tagged post that also mentions AI is skipped (AI_GUARD); at most two images a post.
//        One change: a post's outline tags are joined with their "#" (the Python collector joined them bare, so an
//        outline tag could never match the route written for it).
//        Self-labels are noisy; the router and the battery stand behind them, never auto-flips.
//        The stream is read through MessageStream so tests can feed it canned events.
//

import Foundation
import VeilGardeCore

public protocol MessageStream: AnyObject {
    /// The next text message, or nil when none arrived within `timeout`.
    func next(timeout: TimeInterval) throws -> String?
}

public final class WebSocketStream: MessageStream {
    let task: URLSessionWebSocketTask

    public init(url: URL) {
        task = URLSession(configuration: .ephemeral).webSocketTask(with: url)
        task.maximumMessageSize = 1 << 22
        task.resume()
    }

    deinit { task.cancel(with: .goingAway, reason: nil) }

    public func next(timeout: TimeInterval) throws -> String? {
        let done = DispatchSemaphore(value: 0)
        var result: Result<String?, Error> = .success(nil)
        task.receive { r in
            switch r {
            case .success(.string(let s)): result = .success(s)
            case .success(.data(let d)): result = .success(String(decoding: d, as: UTF8.self))
            case .success: result = .success(nil)
            case .failure(let e): result = .failure(e)
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut { return nil }
        return try result.get()
    }
}

public final class BlueskySource: AcquireSource {
    public let name = "bsky"
    public let rate = 2.0
    public static let jetstream = URL(string: "wss://jetstream2.us-east.bsky.network/subscribe?wantedCollections=app.bsky.feed.post")!

    static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }

    /// (pattern, category, label), first match wins.
    static let routes: [(NSRegularExpression, String, String)] = [
        (regex(#"#(aiart|midjourney|stablediffusion|generativeart|fluxai|fluxdev|dalle|aiartwork|sdxl|comfyui|soraai|aigenerated|nanobanana|grokimagine|aiphoto)\b"#), "art", "generated"),
        (regex(#"#(bokeh|longexposure|motionblur|icmphotography|intentionalcameramovement|lightpainting|panning|slowshutter)\b"#), "blur", "real"),
        (regex(#"#(portraitphotography|portraiture|headshot|selfportrait)\b"#), "human", "real"),
        (regex(#"#(blender3d|b3d|unrealengine|ue5|cgi|3dart|3drender|houdini|cinema4d|octanerender|zbrush|virtualphotography|gamephotography|screenshotsaturday|vgpunite)\b"#), "cgi", "real"),
        (regex(#"#(streetphotography|filmphotography|naturephotography|wildlifephotography|landscapephotography|documentaryphotography|35mm)\b"#), "photo", "real"),
    ]
    static let aiGuard = regex(#"#(aiart|midjourney|stablediffusion|generativeart|fluxai|dalle|ai|aiphoto|nanobanana|soraai)\b|\bai[- ]generated\b"#)

    private var stream: MessageStream?
    private let makeStream: () -> MessageStream
    /// How long one page listens before returning what it has.
    public var pageSeconds: TimeInterval = 60

    public init(stream: MessageStream? = nil) {
        self.stream = stream
        self.makeStream = { WebSocketStream(url: BlueskySource.jetstream) }
    }

    static func matches(_ r: NSRegularExpression, _ s: String) -> Bool { r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// The route of a post's text and tags, or nil.
    public static func route(_ text: String) -> (category: String, label: String)? {
        guard let hit = routes.first(where: { matches($0.0, text) }) else { return nil }
        if hit.2 == "real" && matches(aiGuard, text) { return nil }
        return (hit.1, hit.2)
    }

    /// The images of one Jetstream event that a route keeps.
    public static func items(event: [String: Any]) -> [SourceItem] {
        let commit = JSON.dict(event["commit"]), record = JSON.dict(commit["record"])
        guard JSON.string(commit["operation"]) == "create", JSON.string(record["$type"]) == "app.bsky.feed.post" else { return [] }
        let embed = JSON.dict(record["embed"])
        guard JSON.string(embed["$type"]) == "app.bsky.embed.images", let did = JSON.string(event["did"]), !did.isEmpty else { return [] }
        let tags = JSON.array(record["tags"]).compactMap { $0 as? String }.map { $0.hasPrefix("#") ? $0 : "#" + $0 }
        let text = (JSON.string(record["text"]) ?? "") + " " + tags.joined(separator: " ")
        guard let route = route(text) else { return [] }
        var out: [SourceItem] = []
        for (k, image) in JSON.array(embed["images"]).prefix(2).map(JSON.dict).enumerated() {
            guard let cid = JSON.string(JSON.dict(JSON.dict(image["image"])["ref"])["$link"]) else { continue }
            out.append(SourceItem(id: "\(cid.prefix(24))_\(k)", url: URL(string: "https://cdn.bsky.app/img/feed_fullsize/plain/\(did)/\(cid)@jpeg"),
                                  meta: ["text": String(text.prefix(120))], label: route.label, category: route.category))
        }
        return out
    }

    public func page(query: String, cursor: SourceCursor, http: HTTPClient, key: String?) throws -> (items: [SourceItem], next: SourceCursor?) {
        if stream == nil { stream = makeStream() }
        let started = Date()
        var items: [SourceItem] = []
        while items.count < 20 && Date().timeIntervalSince(started) < pageSeconds {
            let message: String?
            do { message = try stream!.next(timeout: 15) } catch {
                stream = nil                       // dropped without a close frame: reconnect on the next page
                break
            }
            guard let message, let event = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any] else { continue }
            items += Self.items(event: event)
        }
        return (items, [:])
    }
}
