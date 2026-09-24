import Foundation
@testable import PigTV

/// The bundled HLS fixture (PigTVTests/Fixtures/HLS): 6 s of testsrc2 + a
/// 440 Hz tone, H.264 Main 320×180 25 fps + AAC-LC, three 2 s fMP4 segments,
/// `stream.m3u8` (media playlist) and `master.m3u8` (one variant with
/// FRAME-RATE and VIDEO-RANGE=SDR, as the server's buildMasterPlaylist).
enum HLSFixture {
    static let files = ["master.m3u8", "stream.m3u8", "fixture-init.mp4",
                        "fixture-seg0.m4s", "fixture-seg1.m4s", "fixture-seg2.m4s"]

    /// File name → contents, read once from the test bundle.
    static let contents: [String: Data] = {
        let bundle = Bundle(for: BundleToken.self)
        var found: [String: Data] = [:]
        // Synchronized folders may copy resources flat or keep the folder;
        // look for each name anywhere in the bundle.
        let enumerator = FileManager.default.enumerator(at: bundle.bundleURL, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if files.contains(url.lastPathComponent), found[url.lastPathComponent] == nil {
                found[url.lastPathComponent] = try? Data(contentsOf: url)
            }
        }
        return found
    }()

    static var isComplete: Bool { files.allSatisfy { contents[$0] != nil } }

    /// The master playlist with another VIDEO-RANGE (e.g. "PQ").
    static func master(videoRange: String) -> Data {
        let text = String(decoding: contents["master.m3u8"] ?? Data(), as: UTF8.self)
        return Data(text.replacingOccurrences(of: "VIDEO-RANGE=SDR", with: "VIDEO-RANGE=\(videoRange)").utf8)
    }

    static func contentType(_ name: String) -> String {
        if name.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
        if name.hasSuffix(".mp4") { return "video/mp4" }
        return "video/iso.segment"
    }

    private final class BundleToken {}
}

/// A minimal PigTV server for real-playback tests, on one LocalHTTPServer:
/// - `POST /api/playback/resolve` → the decision `resolve` returns (by default,
///   session `s<n>` pointing at `/api/transcode/s<n>/master.m3u8`);
/// - `GET /api/transcode/<session>/<file>` → the HLS fixture (any session;
///   a session whose name contains `pq` serves a VIDEO-RANGE=PQ master);
/// - `GET /api/playback/conflict` → `null`;
/// - `POST /api/playback/client-event`, `POST /api/playback/conflict/decline`,
///   `DELETE /api/playback/<session>` → `{"success":true}`.
/// Anything else is a 404, and every request is recorded.
final class FakePigTVServer: @unchecked Sendable {
    let http: LocalHTTPServer

    /// `resolve(n)` builds the n-th resolve answer (1-based) as JSON.
    init(resolve: (@Sendable (Int, LocalHTTPServer.Request) -> LocalHTTPServer.Response)? = nil) throws {
        let counter = Locked(0)
        let resolve = resolve ?? { count, _ in FakePigTVServer.decision(session: "s\(count)") }
        http = try LocalHTTPServer { request in
            FakePigTVServer.route(request, counter: counter, resolve: resolve)
        }
    }

    var resolves: [LocalHTTPServer.Request] { http.requests(path: "/api/playback/resolve", method: "POST") }

    /// Resolve bodies as JSON objects, in order.
    func resolveBodies() -> [[String: Any]] {
        resolves.compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
    }

    /// Client events (`event` names) in the order received.
    func clientEvents() -> [String] {
        http.requests(path: "/api/playback/client-event", method: "POST").compactMap {
            (try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any])?["event"] as? String
        }
    }

    /// Server info advertising client events, so play-start/-end are posted.
    static func info() throws -> ServerInfo {
        try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"3.9.0","build":"0146","apiVersion":1,"features":{"library":true,"playbackResolve":true,"clientEvents":true,"viewerConflict":true}}"#.utf8))
    }

    /// An APIClient for this server (token "fixture").
    func client() throws -> APIClient {
        APIClient(address: try ServerAddress(http.baseURL), token: "fixture", info: try Self.info())
    }

    static func decision(session: String, playlist: String = "master.m3u8", fps: String? = "25/1",
                         videoRange: String? = nil) -> LocalHTTPServer.Response {
        var info: [String] = []
        if let fps { info.append(#""fps":"\#(fps)""#) }
        if let videoRange { info.append(#""videoRange":"\#(videoRange)""#) }
        info.append(#""video":"h264","width":320,"height":180"#)
        return .json(#"{"strategy":"transcode","url":"/api/transcode/\#(session)/\#(playlist)","sessionId":"\#(session)","container":"hls","videoMode":"copy","info":{\#(info.joined(separator: ","))}}"#)
    }

    private static func route(_ request: LocalHTTPServer.Request, counter: Locked<Int>,
                              resolve: @Sendable (Int, LocalHTTPServer.Request) -> LocalHTTPServer.Response) -> LocalHTTPServer.Response {
        let path = request.path
        switch (request.method, path) {
        case ("POST", "/api/playback/resolve"):
            counter.value += 1
            return resolve(counter.value, request)
        case ("GET", "/api/playback/conflict"):
            return .json("null")
        case ("POST", "/api/playback/client-event"), ("POST", "/api/playback/conflict/decline"):
            return .json(#"{"success":true}"#)
        default:
            break
        }
        let parts = path.split(separator: "/").map(String.init)
        if request.method == "DELETE", parts.count == 3, parts[0] == "api", parts[1] == "playback" {
            return .json(#"{"success":true}"#)
        }
        if ["GET", "HEAD"].contains(request.method), parts.count == 4, parts[0] == "api", parts[1] == "transcode" {
            let session = parts[2]
            let name = parts[3]
            if name == "master.m3u8", session.contains("pq") {
                return .init(status: 200, contentType: HLSFixture.contentType(name), body: HLSFixture.master(videoRange: "PQ"))
            }
            if let data = HLSFixture.contents[name] {
                return .init(status: 200, contentType: HLSFixture.contentType(name), body: data)
            }
        }
        return .notFound
    }
}
