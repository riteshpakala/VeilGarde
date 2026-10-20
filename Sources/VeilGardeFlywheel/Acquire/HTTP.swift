//
//  HTTP.swift
//  VeilGardeFlywheel
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The acquisition's network: a transport (URLSession, or a stand-in in tests), a per-source
//        rate limit that listing and downloads share, and the collectors' retry rules.
//  PIN:  atlas_collect.py's engine: a listing call is retried 4 times on 429/5xx or a transport
//        error, sleeping 8·2^n s; a download 3 times on 429/500/502/503, sleeping 5·2^n s; only
//        image/jpeg, image/png and image/webp (or a .jpg URL) of at least 20,000 bytes are kept;
//        every request carries the collector's User-Agent. Synchronous by design: acquisition runs
//        on the one thread that also runs MLX, one image at a time.
//

import Foundation
import VeilGardeCore

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var contentType: String { (headers.first { $0.key.lowercased() == "content-type" }?.value ?? "").split(separator: ";").first.map(String.init) ?? "" }
}

public protocol HTTPTransport: AnyObject {
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) throws -> HTTPResponse
}

public final class URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func get(_ url: URL, headers: [String: String], timeout: TimeInterval) throws -> HTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let done = DispatchSemaphore(value: 0)
        var result: Result<HTTPResponse, Error> = .failure(VeilGardeFailure.temporary("no response from \(url.host ?? "?")"))
        session.dataTask(with: request) { data, response, error in
            if let error { result = .failure(error) } else if let http = response as? HTTPURLResponse {
                var h: [String: String] = [:]
                for (k, v) in http.allHeaderFields { h["\(k)"] = "\(v)" }
                result = .success(HTTPResponse(status: http.statusCode, headers: h, body: data ?? Data()))
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }
}

/// A minimum interval between requests to one source.
public final class RateLimiter {
    public let perSecond: Double
    private var last: Date = .distantPast
    private let sleep: (TimeInterval) -> Void

    public init(perSecond: Double, sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.perSecond = perSecond
        self.sleep = sleep
    }

    public func wait() {
        let gap = 1 / perSecond - Date().timeIntervalSince(last)
        if gap > 0 { sleep(gap) }
        last = Date()
    }
}

public final class HTTPClient {
    public static let userAgent = "VeilGarde-collector/\(VeilGardeVersion.string) (features-only research store; nothing kept but features)"
    public static let minimumBytes = 20_000
    public static let imageTypes = ["image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"]

    public let transport: HTTPTransport
    public let limiter: RateLimiter
    let sleep: (TimeInterval) -> Void

    public init(transport: HTTPTransport, rate: Double, sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.transport = transport
        self.limiter = RateLimiter(perSecond: rate, sleep: sleep)
        self.sleep = sleep
    }

    public static func url(_ base: String, _ params: [(String, String)]) -> URL {
        var c = URLComponents(string: base)!
        if !params.isEmpty { c.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) } }
        return c.url!
    }

    /// A listing call's JSON, or nil after the retries.
    public func json(_ url: URL, headers: [String: String] = [:], tries: Int = 4) -> Any? {
        for attempt in 0..<tries {
            limiter.wait()
            do {
                let r = try transport.get(url, headers: headers.merging(["User-Agent": Self.userAgent]) { a, _ in a }, timeout: 30)
                if r.status == 200 { return try? JSONSerialization.jsonObject(with: r.body) }
                if [429, 500, 502, 503, 504].contains(r.status) { sleep(8 * pow(2, Double(attempt))); continue }
                return nil
            } catch {
                sleep(8 * pow(2, Double(attempt)))
            }
        }
        return nil
    }

    /// An image's bytes, or nil (a refused type, a short file, an error after the retries).
    public func image(_ url: URL, headers: [String: String] = [:]) -> Data? {
        for attempt in 0..<3 {
            limiter.wait()
            guard let r = try? transport.get(url, headers: headers.merging(["User-Agent": Self.userAgent]) { a, _ in a }, timeout: 60) else { return nil }
            if [429, 500, 502, 503].contains(r.status) { sleep(5 * pow(2, Double(attempt))); continue }
            guard r.status == 200 else { return nil }
            let typed = Self.imageTypes[r.contentType] != nil
                || ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
            guard typed, r.body.count >= Self.minimumBytes else { return nil }
            return r.body
        }
        return nil
    }
}
