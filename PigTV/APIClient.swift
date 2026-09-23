import Foundation
import CryptoKit

struct ServerAddress: Equatable {
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
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// Artwork alone may follow redirects. Re-evaluate origin at every hop.
private final class ArtworkRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
    private let artworkCache: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.totalCostLimit = 16 * 1024 * 1024
        cache.countLimit = 200
        return cache
    }()
    private lazy var artworkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 0)
        return URLSession(configuration: configuration, delegate: ArtworkRedirects(address: address, token: token), delegateQueue: nil)
    }()

    init(address: ServerAddress, token: String? = nil, session: URLSession? = nil, info: ServerInfo? = nil) {
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
            if serverError?.error == "Transcode failed to produce a playlist in time" {
                throw PigTVError.message("The server could not prepare the stream before its startup deadline. No video was received. Try again after checking the server's playback log.")
            }
            throw PigTVError.http(response.statusCode)
        }
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

    @MainActor
    // Logos persist on disk between launches, so the guide does not re-download
    // every channel's artwork each cold start (only decoding is repeated).
    private static let artworkDiskCache: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("PigTVArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static func artworkDiskURL(for url: URL) -> URL? {
        guard let dir = artworkDiskCache else { return nil }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return dir.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
    }

    func artworkData(_ logo: String) async throws -> Data? {
        guard let request = artworkRequest(logo), let url = request.url else { return nil }
        if let cached = artworkCache.object(forKey: url as NSURL) { return cached as Data }
        let diskURL = Self.artworkDiskURL(for: url)
        if let diskURL, let data = await Task.detached(priority: .utility, operation: {
            try? Data(contentsOf: diskURL)
        }).value {
            artworkCache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            return data
        }
        let (file, response) = try await artworkSession.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        let data: Data? = await Task.detached(priority: .utility) {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 4 * 1024 * 1024 else { return nil }
            return try? Data(contentsOf: file)
        }.value
        guard let data else { return nil }

        artworkCache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        if let diskURL { try? data.write(to: diskURL, options: .atomic) }
        return data
    }

    func guidePage(query: [URLQueryItem]) async throws -> GuidePage {
        let data = try await send("library/guide", method: "GET", query: query)
        return try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(GuidePage.self, from: data)
        }.value
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
