import Foundation
import CryptoKit

nonisolated struct ServerAddress: Equatable, Sendable {
    let url: URL

    init(_ text: String) throws {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw PigTVError.invalidServerURL
        }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        parts.path = "/"
        guard let url = parts.url else { throw PigTVError.invalidServerURL }
        self.url = url
    }

    func contains(_ candidate: URL) -> Bool {
        candidate.scheme?.lowercased() == url.scheme &&
        candidate.host?.lowercased() == url.host &&
        (candidate.port ?? (candidate.scheme == "https" ? 443 : 80)) == (url.port ?? (url.scheme == "https" ? 443 : 80)) &&
        candidate.user == nil && candidate.password == nil
    }
}

// API requests never follow redirects: credentials must stay on the chosen server.
// Swift 6: URLSession calls delegates on its own queue, so the delegates are
// nonisolated (the app's default isolation is the main actor).
private nonisolated final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// Artwork alone may follow redirects. Re-evaluate origin at every hop.
private nonisolated final class ArtworkRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let address: ServerAddress
    let token: String?
    init(address: ServerAddress, token: String?) { self.address = address; self.token = token }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ["http", "https"].contains(url.scheme ?? ""),
              url.user == nil, url.password == nil else { completionHandler(nil); return }
        var next = request
        next.setValue(address.contains(url) ? token.map { "Bearer \($0)" } : nil, forHTTPHeaderField: "Authorization")
        completionHandler(next)
    }
}

final class APIClient {
    let address: ServerAddress
    let info: ServerInfo?
    private let token: String?
    private let session: URLSession
    // Keyed by the canonical artwork key (server-qualified, token removed).
    private let artworkCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 16 * 1024 * 1024
        cache.countLimit = 200
        return cache
    }()
    /// Largest artwork response accepted, enforced while it streams in.
    var artworkMaxBytes = 4 * 1024 * 1024
    private let artworkStore: ArtworkDiskStore
    private let artworkProtocols: [AnyClass]?
    // One task per logo: several cells asking for it share one fetch. The
    // task is unstructured, so one awaiter being cancelled leaves the rest.
    private var artworkFetches: [String: Task<Data?, any Error>] = [:]
    private lazy var artworkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        if let artworkProtocols { configuration.protocolClasses = artworkProtocols }
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 0)
        return URLSession(configuration: configuration, delegate: ArtworkRedirects(address: address, token: token), delegateQueue: nil)
    }()

    init(address: ServerAddress, token: String? = nil, session: URLSession? = nil, info: ServerInfo? = nil,
         artworkStore: ArtworkDiskStore = .shared) {
        self.artworkStore = artworkStore
        // A test's injected session carries its URLProtocol stubs; artwork
        // goes through the same stubs.
        self.artworkProtocols = session?.configuration.protocolClasses
        self.address = address
        self.info = info
        self.token = token
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 35
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        }
    }

    deinit { session.invalidateAndCancel() }

    func requestURL(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard !path.contains("?"), !path.contains("#"), !path.contains(".."), !path.hasPrefix("/") else {
            throw PigTVError.invalidServerURL
        }
        var parts = URLComponents(url: address.url.appendingPathComponent("api").appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        // Express treats a raw '+' as a space when parsing query parameters.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw PigTVError.invalidServerURL }
        return url
    }

    func request<T: Decodable>(_ path: String, method: String = "GET",
                               query: [URLQueryItem] = [], body: (any Encodable)? = nil) async throws -> T {
        let data = try await send(path, method: method, query: query, body: body)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw PigTVError.decoding }
    }

    /// Build 31: like `request`, but the JSON is decoded off the main actor
    /// (recordings lists can be long; they were decoded on the main thread
    /// on every Recordings/Guide/Home appearance).
    func decodedOffMain<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(path, method: "GET", query: query)
        return try await Task.detached(priority: .userInitiated) {
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw PigTVError.decoding }
        }.value
    }

    private func send(_ path: String, method: String, query: [URLQueryItem] = [],
                      body: (any Encodable)? = nil) async throws -> Data {
        try await response(path, method: method, query: query, body: body).data
    }

    struct Response {
        let status: Int
        let data: Data
        let retryAfter: Double?
    }

    func response(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                  body: (any Encodable)? = nil, timeout: TimeInterval? = nil) async throws -> Response {
        var request = URLRequest(url: try requestURL(path, query: query))
        if let timeout { request.timeoutInterval = max(0.1, timeout) }
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PigTVError.http(0) }
        switch response.statusCode {
        case 200..<300: return Response(status: response.statusCode, data: data,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        case 401: throw PigTVError.unauthorised
        case 403: throw PigTVError.forbidden
        default:
            // Parse only known, actionable server errors. Never display raw
            // upstream errors, which may contain subscription URLs/passwords.
            let serverError = try? JSONDecoder().decode(ServerErrorResponse.self, from: data)
            if response.statusCode == 409, let conflict = serverError?.conflict {
                if conflict.type == "viewer-in-progress" {
                    throw PigTVError.viewerConflict(message: conflict.message ?? "Another device is watching. Watching here will stop its stream.")
                }
                if let recording = conflict.recording { throw PigTVError.recordingConflict(recording) }
            }
            if response.statusCode == 429 {
                let seconds = serverError?.retryAfterSec ?? response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) ?? 60
                throw PigTVError.rateLimited(retryAfterSec: max(1, seconds))
            }
            if response.statusCode == 500, path.hasPrefix("recordings/"), path.hasSuffix("/playback") {
                throw PigTVError.recordingPreparationFailed(reason: serverError?.reason)
            }
            // C-B: a failed resolve may carry a sentence written to be shown.
            // Only an allow-listed prefix is displayed; all else stays generic.
            if path == "playback/resolve", let shown = Self.displayableResolveError(serverError?.error) {
                throw PigTVError.message(shown)
            }
            if serverError?.error == "Transcode failed to produce a playlist in time" {
                throw PigTVError.message("The server could not prepare the stream before its startup deadline. No video was received. Try again after checking the server's playback log.")
            }
            throw PigTVError.http(response.statusCode)
        }
    }

    // Contract C-B: the resolve `error` texts the client may show verbatim.
    static let displayableResolveErrorPrefixes = [
        "The provider refused this channel",
        "The provider did not respond",
        "This channel is not available"
    ]

    /// The text to show for a failed resolve's `error`, or nil to keep the
    /// generic mapping. The server promises these never contain a URL; one
    /// that does (defence in depth) is still treated as unknown. "HTTP 403"
    /// style status text is part of the approved wording and is kept.
    static func displayableResolveError(_ error: String?) -> String? {
        guard let text = error?.trimmingCharacters(in: .whitespacesAndNewlines),
              displayableResolveErrorPrefixes.contains(where: { text.hasPrefix($0) }),
              !text.contains("://") else { return nil }
        return String(text.prefix(300))
    }

    // Poll only when advertised. A terminal error must stop: the next request
    // after a preparation failure starts a fresh remux on the server.
    @MainActor
    func recordingPlayback(id: Int, timeout: TimeInterval = 600,
                           now: () -> Date = Date.init,
                           sleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                           preparing: () -> Void = {}) async throws -> RecordingPlayback {
        let deadline = now().addingTimeInterval(timeout)
        let query = info?.features.recordingPlaybackPolling == true ? [URLQueryItem(name: "async", value: "1")] : []
        while true {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else { throw PigTVError.message("Preparing the recording took too long. Try again when the server is ready.") }
            let result = try await response("recordings/\(id)/playback", query: query, timeout: min(35, remaining))
            try Task.checkCancellation()
            guard now() < deadline else { throw PigTVError.message("Preparing the recording took too long. Try again when the server is ready.") }
            if result.status == 200 {
                guard let playback = try? JSONDecoder().decode(RecordingPlayback.self, from: result.data) else { throw PigTVError.decoding }
                return playback
            }
            guard !query.isEmpty, result.status == 202,
                  let pending = try? JSONDecoder().decode(RecordingPreparing.self, from: result.data),
                  pending.status == "preparing" else { throw PigTVError.decoding }
            preparing()
            let rawDelay = pending.retryAfterSec ?? result.retryAfter ?? 3
            let delay = rawDelay.isFinite && rawDelay > 0 ? max(1, rawDelay) : 3
            try await sleep(min(delay, max(0, deadline.timeIntervalSince(now()))))
        }
    }

    /// R11: asks the server to start the stream for `body`'s channel ahead of
    /// a play (the same body resolve sends). Nil for 204 (setting off, nothing
    /// free, already watching it, any server-side failure: do nothing). The
    /// request may wait several seconds; callers run it in a cancellable task.
    func warm(_ body: ResolveBody, timeout: TimeInterval = 25) async throws -> WarmResult? {
        let result = try await response("playback/warm", method: "POST", body: body, timeout: timeout)
        guard result.status == 200 else { return nil }
        return try? JSONDecoder().decode(WarmResult.self, from: result.data)
    }

    func reportPlaybackEvent(_ event: PlaybackEvent) async {
        guard info?.features.clientEvents == true else { return }
        var event = event
        if let path = event.path { event.path = (try? playbackURL(path))?.path }
        _ = try? await response("playback/client-event", method: "POST", body: event, timeout: 3)
    }

    // Keep credentials on the configured origin, including for relative logos.
    func artworkRequest(_ logo: String) -> URLRequest? {
        guard !logo.isEmpty,
              let url = URL(string: logo, relativeTo: address.url)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        var request = URLRequest(url: url)
        if address.contains(url), let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return request
    }

    /// The canonical cache key for a logo on this server.
    func artworkKey(_ logo: String) -> String? { ArtworkKey.key(logo: logo, address: address) }

    // Logos persist on disk between launches (bounded: see ArtworkDiskStore),
    // so the guide does not re-download every channel's artwork each cold
    // start (only decoding is repeated).
    func artworkData(_ logo: String) async throws -> Data? {
        guard let request = artworkRequest(logo), let url = request.url else { return nil }
        let key = ArtworkKey.canonical(url)
        if let cached = artworkCache.object(forKey: key as NSString) { return cached as Data }
        if let pending = artworkFetches[key] { return try await pending.value }
        let session = artworkSession, store = artworkStore, limit = artworkMaxBytes
        let task = Task<Data?, any Error> {
            defer { artworkFetches[key] = nil }
            let data = try await Task.detached(priority: .utility) {
                try await Self.loadArtwork(request, key: key, session: session, store: store, limit: limit)
            }.value
            if let data { artworkCache.setObject(data as NSData, forKey: key as NSString, cost: data.count) }
            return data
        }
        artworkFetches[key] = task
        return try await task.value
    }

    /// Disk first, else the network. Runs off the main actor: the body is
    /// read incrementally and abandoned as soon as it passes `limit` (the
    /// declared Content-Length is checked first), and the disk write happens
    /// here, not on the caller.
    private nonisolated static func loadArtwork(_ request: URLRequest, key: String, session: URLSession,
                                               store: ArtworkDiskStore, limit: Int) async throws -> Data? {
        if let data = store.read(key: key) { return data }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            bytes.task.cancel()
            return nil
        }
        if http.expectedContentLength > Int64(limit) { bytes.task.cancel(); return nil }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { bytes.task.cancel(); return nil }
        }
        store.write(data, key: key)
        return data
    }

    func guidePage(query: [URLQueryItem]) async throws -> GuidePage {
        let data = try await send("library/guide", method: "GET", query: query)
        return try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(GuidePage.self, from: data)
        }.value
    }
    // A1.1: server flag `guideVersion`. Changes when channel data, visibility,
    // order, logos or EPG change — never merely because time passed.
    private struct GuideVersionResponse: Decodable { let version: String }
    func guideVersion() async throws -> String {
        let result: GuideVersionResponse = try await request("library/guide/version")
        return result.version
    }
    func epgArtwork(sourceID: Int) async throws -> EPGArtworkPage {
        let data = try await send("proxy/epg/\(sourceID)", method: "GET")
        return try await Task.detached(priority: .utility) {
            try JSONDecoder().decode(EPGArtworkPage.self, from: data)
        }.value
    }

    func release(_ sessionID: String) async throws {
        guard validSessionID(sessionID) else {
            throw PigTVError.message("The server returned an invalid playback session identifier.")
        }
        _ = try await send("playback/\(sessionID)", method: "DELETE")
    }

    // A displaced HLS player otherwise sees the same 404 as an ordinary
    // expiry. This check is deliberately best-effort: legacy servers, route
    // errors and a slow server must retain the existing one-time C2 recovery.
    func sessionWasTakenOver(_ sessionID: String) async -> Bool {
        guard info?.features.playbackTerminalStatus == true, validSessionID(sessionID) else { return false }
        do {
            let result = try await response("playback/\(sessionID)/terminal-status", timeout: 3)
            let terminal = try JSONDecoder().decode(PlaybackTerminalStatus.self, from: result.data)
            return terminal.status == "taken-over"
        } catch {
            return false
        }
    }

    private func validSessionID(_ sessionID: String) -> Bool {
        !sessionID.isEmpty && sessionID.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    func playbackURL(_ relative: String) throws -> URL {
        guard let url = URL(string: relative, relativeTo: address.url)?.absoluteURL,
              address.contains(url), url.fragment == nil,
              ["/api/proxy/stream"].contains(url.path) || url.path.hasPrefix("/api/transcode/")
                || url.path.hasPrefix("/api/recordings/"),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PigTVError.message("The server returned a playback URL outside its media endpoints.")
        }
        if let token {
            parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "token" } + [URLQueryItem(name: "token", value: token)]
        }
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let result = parts.url else { throw PigTVError.invalidServerURL }
        return result
    }
}
