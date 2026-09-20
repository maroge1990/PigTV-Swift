import XCTest
import AVFoundation
@testable import PigTV

// URLProtocol intercepts every request, including unexpected routes. No fixture
// can fall through to a real server. Tests run serially in the shared scheme.
private final class SyntheticServer: @unchecked Sendable {
    struct Reply {
        var status: Int
        var json: String
        var delay: TimeInterval = 0
    }
    private let lock = NSLock()
    private var requests: [(path: String, method: String, body: Data)] = []
    private let handler: @Sendable (String, String, Int) -> Reply

    init(_ handler: @escaping @Sendable (String, String, Int) -> Reply) { self.handler = handler }

    func receive(_ request: URLRequest) -> Reply {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let size = stream.read(&bytes, maxLength: bytes.count)
                if size <= 0 { break }
                body.append(contentsOf: bytes.prefix(size))
            }
        }
        return lock.withLock {
            let path = request.url!.path
            let method = request.httpMethod ?? "GET"
            requests.append((path, method, body))
            return handler(path, method, requests.filter { $0.path == path }.count)
        }
    }

    var captured: [(path: String, method: String, body: Data)] { lock.withLock { requests } }
}

private final class SyntheticProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server: SyntheticServer!
    private let lock = NSRecursiveLock()
    private var cancelled = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.server.receive(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            lock.withLock {
                guard !cancelled else { return }
                let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() { lock.withLock { cancelled = true } }
}

@MainActor
final class PlaybackLifecycleTests: XCTestCase {
    private let viewer = #"{"conflict":{"type":"viewer-in-progress","message":"Another device is watching."}}"#

    private func client(_ server: SyntheticServer, modern: Bool = false) throws -> APIClient {
        SyntheticProtocol.server = server
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticProtocol.self]
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"3.7.0","build":"0086","apiVersion":1,"features":{"library":true,"playbackResolve":true,"recordingPlaybackPolling":true,"epgLogoFallback":true}}"#.utf8))
        return APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
            session: URLSession(configuration: configuration), info: modern ? info : nil)
    }

    private func model(_ client: APIClient) -> PlaybackModel {
        PlaybackModel(channel: Channel(rawID: "42", sourceId: 1, name: "Synthetic",
            logo: nil, category: nil, now: nil, next: nil), client: client)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    func testViewerTakeoverRequiresExplicitAction() async throws {
        let viewer = viewer
        let server = SyntheticServer { _, _, _ in .init(status: 409, json: viewer) }
        let playback = model(try client(server))
        playback.start()
        try await eventually { playback.viewerConflict != nil }
        XCTAssertEqual(server.captured.count, 1)
        let first = try JSONSerialization.jsonObject(with: server.captured[0].body) as! [String: Any]
        XCTAssertEqual(first["force"] as? Bool, false)
        playback.start() // a repeated appearance cannot bypass a conflict prompt
        XCTAssertEqual(server.captured.count, 1)
        playback.confirmViewerStop()
        try await eventually { server.captured.count == 2 && playback.viewerConflict != nil }
        let confirmed = try JSONSerialization.jsonObject(with: server.captured[1].body) as! [String: Any]
        XCTAssertEqual(confirmed["force"] as? Bool, true)
        _ = await playback.stop()
    }

    func testRepeatedFailureSignalsAllowOnlyOneAutomaticResolve() async throws {
        let server = SyntheticServer { _, _, _ in .init(status: 503, json: "{}") }
        let playback = model(try client(server))
        playback.playbackStarted() // AVPlayer's playing signal, without real media.
        playback.playbackFailed(detail: "Synthetic failure")
        playback.playbackFailed(detail: "Duplicate failure")
        try await eventually { playback.error != nil }
        XCTAssertEqual(server.captured.count, 1)
        XCTAssertTrue(playback.canRetry)
        XCTAssertFalse(playback.reconnecting)
        XCTAssertTrue(playback.error!.contains("The stream ended"))
        let request = try JSONSerialization.jsonObject(with: server.captured[0].body) as! [String: Any]
        XCTAssertEqual(request["force"] as? Bool, false)
        playback.playbackFailed(detail: "Another signal")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(server.captured.count, 1)
        playback.retry()
        try await eventually { server.captured.count == 2 && playback.error != nil }
        _ = await playback.stop()
    }

    func testRecoveryConflictDoesNotForceTakeover() async throws {
        let viewer = viewer
        let server = SyntheticServer { _, _, _ in .init(status: 409, json: viewer) }
        let playback = model(try client(server))
        playback.playbackStarted()
        playback.playbackFailed(detail: "Session expired")
        try await eventually { playback.viewerConflict != nil }
        XCTAssertEqual(server.captured.count, 1)
        XCTAssertNil(playback.error)
        XCTAssertFalse(playback.reconnecting)
        _ = await playback.stop()
        playback.confirmViewerStop()
        playback.retry()
        XCTAssertEqual(server.captured.count, 1)
    }

    func testInitialMediaFailureDoesNotAutomaticallyResolve() async throws {
        let server = SyntheticServer { _, _, _ in .init(status: 500, json: "{}") }
        let playback = model(try client(server))
        playback.playbackFailed(detail: "Route: transcode. PlayerError -1")
        XCTAssertTrue(playback.error!.contains("Playback could not start"))
        XCTAssertTrue(playback.canRetry)
        playback.start() // a repeated appearance is not a manual Retry
        XCTAssertTrue(server.captured.isEmpty)
        _ = await playback.stop()
    }

    func testDismissedResolveReleasesLateSessionWithoutInstallingMedia() async throws {
        let server = SyntheticServer { path, method, _ in
            if path == "/api/playback/resolve" {
                return .init(status: 200, json: #"{"strategy":"transcode","url":"/api/transcode/late/stream.m3u8","sessionId":"late","container":"hls"}"#, delay: 0.1)
            }
            return .init(status: method == "DELETE" ? 200 : 500, json: #"{"success":true}"#)
        }
        let playback = model(try client(server))
        playback.start()
        try await eventually { !server.captured.isEmpty }
        let warning = await playback.stop()
        XCTAssertNil(warning)
        XCTAssertFalse(playback.ready)
        XCTAssertNil(playback.player.currentItem)
        XCTAssertEqual(server.captured.map(\.path), ["/api/playback/resolve", "/api/playback/late"])
        XCTAssertEqual(server.captured.last?.method, "DELETE")
        playback.start()
        XCTAssertEqual(server.captured.count, 2)
    }

    func testStoppingBeforeRecoveryTaskRunsPreventsResolve() async throws {
        let server = SyntheticServer { _, _, _ in .init(status: 500, json: "{}") }
        let playback = model(try client(server))
        playback.playbackStarted()
        playback.playbackFailed(detail: "Expired")
        _ = await playback.stop()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(server.captured.isEmpty)
    }

    func testRecordingDismissDuringPreparationStopsPolling() async throws {
        let server = SyntheticServer { path, _, _ in
            if path.hasSuffix("markers") { return .init(status: 200, json: #"{"markers":[]}"#) }
            return .init(status: 202, json: #"{"status":"preparing","retryAfterSec":1}"#)
        }
        let recording = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":12,"title":"Synthetic","status":"completed"}"#.utf8))
        let playback = RecordingPlayerModel(recording: recording, client: try client(server, modern: true))
        playback.start()
        try await eventually { playback.preparing }
        await playback.stop()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(server.captured.filter { $0.path.hasSuffix("playback") }.count, 1)
        XCTAssertNil(playback.player.currentItem)
        XCTAssertFalse(playback.ready)
        XCTAssertNil(playback.error)
    }

    func testRecordingDismissDuringResponseNeverStartsMedia() async throws {
        let server = SyntheticServer { path, _, _ in
            if path.hasSuffix("markers") { return .init(status: 200, json: #"{"markers":[]}"#) }
            return .init(status: 200, json: #"{"url":"/api/recordings/12/media.mp4","container":"mp4"}"#, delay: 0.2)
        }
        let recording = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":12,"title":"Synthetic","status":"completed"}"#.utf8))
        let playback = RecordingPlayerModel(recording: recording, client: try client(server, modern: true))
        playback.start()
        try await eventually { server.captured.count == 2 }
        await playback.stop()
        XCTAssertNil(playback.player.currentItem)
        XCTAssertFalse(playback.ready)
    }

    func testRecordingPreparationFailureRequiresExplicitRetry() async throws {
        let server = SyntheticServer { path, _, _ in
            if path.hasSuffix("markers") { return .init(status: 200, json: #"{"markers":[]}"#) }
            return .init(status: 500, json: #"{"status":"failed","reason":"file-missing"}"#)
        }
        let recording = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":12,"title":"Synthetic","status":"completed"}"#.utf8))
        let playback = RecordingPlayerModel(recording: recording, client: try client(server, modern: true))
        playback.start()
        try await eventually { playback.canRetry }
        XCTAssertTrue(playback.error!.contains("missing"))
        playback.start()
        XCTAssertEqual(server.captured.filter { $0.path.hasSuffix("playback") }.count, 1)
        playback.retry()
        try await eventually { server.captured.filter { $0.path.hasSuffix("playback") }.count == 2 && playback.canRetry }
        await playback.stop()
    }

    func testServerLogoFallbackSkipsArtworkIndexRequestsAndWaitingIsNotRecording() async throws {
        let server = SyntheticServer { _, _, _ in .init(status: 500, json: "{}") }
        let browse = BrowseModel(client: try client(server, modern: true))
        await browse.loadArtworkIndex()
        XCTAssertTrue(server.captured.isEmpty)
        browse.schedules = try JSONDecoder().decode([ScheduledRecording].self, from: Data(#"[{"id":7,"title":"Show","channel_name":"Synthetic","program_start":1000,"program_end":3000,"status":"waiting"}]"#.utf8))
        XCTAssertTrue(browse.recordingChannels.isEmpty)
        XCTAssertEqual(browse.scheduledKeys.count, 1)
    }
}
