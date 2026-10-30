import XCTest
import AVFoundation
import UIKit
import Combine
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

    private func client(_ server: SyntheticServer, modern: Bool = false, address: String = "https://fixture.invalid") throws -> APIClient {
        SyntheticProtocol.server = server
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticProtocol.self]
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"3.7.0","build":"0086","apiVersion":1,"features":{"library":true,"playbackResolve":true,"recordingPlaybackPolling":true,"epgLogoFallback":true,"playbackTerminalStatus":true}}"#.utf8))
        return APIClient(address: try ServerAddress(address), token: "fixture",
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

    func testConfirmedTakeoverNeverReleasesOrResolves() async throws {
        let server = SyntheticServer { _, _, _ in .init(status: 200, json: #"{"status":"taken-over"}"#) }
        let playback = model(try client(server, modern: true))
        await playback.recoverAfterFailure(session: "removed")
        XCTAssertEqual(server.captured.map(\.path), ["/api/playback/removed/terminal-status"])
        XCTAssertEqual(playback.error, "Playback moved to another device.")
        XCTAssertFalse(playback.canRetry)
        _ = await playback.stop()
        XCTAssertEqual(server.captured.count, 1)
    }

    func testNormalExpiryStillResolvesOnce() async throws {
        let server = SyntheticServer { path, _, _ in
            path.hasSuffix("terminal-status") ? .init(status: 200, json: #"{"status":"none"}"#) : .init(status: 503, json: "{}")
        }
        let playback = model(try client(server, modern: true))
        await playback.recoverAfterFailure(session: "expired")
        try await eventually { playback.error != nil }
        XCTAssertEqual(server.captured.map(\.path), ["/api/playback/expired/terminal-status", "/api/playback/resolve"])
        _ = await playback.stop()
    }

    func testDismissDuringTerminalCheckCannotChangeStoppedPlayer() async throws {
        let server = SyntheticServer { _, _, _ in .init(status: 200, json: #"{"status":"taken-over"}"#, delay: 0.1) }
        let playback = model(try client(server, modern: true))
        let recovery = Task { await playback.recoverAfterFailure(session: "removed") }
        try await eventually { server.captured.count == 1 }
        _ = await playback.stop()
        await recovery.value
        XCTAssertNil(playback.error)
        XCTAssertEqual(server.captured.count, 1)
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

    /// #5: simultaneous failure signals are one failure; a reconnect whose resolve keeps failing tries again up to
    /// the window's three re-resolves (never forced), then shows the error with Retry.
    func testRepeatedFailureSignalsAreOneFailureAndReResolvesAreBounded() async throws {
        let server = SyntheticServer { _, _, _ in .init(status: 503, json: "{}") }
        let playback = model(try client(server))
        playback.recoveryDelays = [0, 0, 0]
        playback.playbackStarted() // AVPlayer's playing signal, without real media.
        playback.playbackFailed(detail: "Synthetic failure")
        playback.playbackFailed(detail: "Duplicate failure")
        try await eventually { playback.error != nil }
        XCTAssertEqual(server.captured.count, 3, "three re-resolves in the window, then the error")
        XCTAssertTrue(playback.canRetry)
        XCTAssertFalse(playback.reconnecting)
        XCTAssertTrue(playback.error!.contains("The stream ended"))
        for request in server.captured {
            let body = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            XCTAssertEqual(body["force"] as? Bool, false)
        }
        playback.playbackFailed(detail: "Another signal")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(server.captured.count, 3)
        playback.retry()
        try await eventually { server.captured.count == 4 && playback.error != nil }
        _ = await playback.stop()
    }

    /// #139: a reconnect's resolve that fails for a permanent reason shows the error at once, without retries.
    func testPermanentResolveErrorsAreNotRetried() async throws {
        for status in [401, 403, 404, 409] {
            let server = SyntheticServer { _, _, _ in .init(status: status, json: #"{"error":"no"}"#) }
            let playback = model(try client(server))
            playback.recoveryDelays = [0, 0, 0]
            playback.playbackStarted()
            playback.playbackFailed(detail: "Synthetic failure")
            try await eventually { playback.error != nil }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(server.captured.filter { $0.path == "/api/playback/resolve" }.count, 1, "HTTP \(status) is not retried")
            _ = await playback.stop()
        }
        XCTAssertNil(PlaybackModel.retryWait(after: PigTVError.decoding))
        XCTAssertEqual(PlaybackModel.retryWait(after: PigTVError.http(503)), 0)
        XCTAssertEqual(PlaybackModel.retryWait(after: URLError(.timedOut)), 0)
        XCTAssertNil(PlaybackModel.retryWait(after: PigTVError.rateLimited(retryAfterSec: 120)))
    }

    /// #147: a provider timeout the server explains in a sentence (shown to the viewer) is still a 5xx: retried.
    func testAShownProviderTimeoutIsRetried() async throws {
        for status in [500, 503] {
            let server = SyntheticServer { _, _, _ in
                .init(status: status, json: #"{"error":"The provider did not respond in time. It may be busy; try again in a few seconds."}"#)
            }
            let playback = model(try client(server))
            playback.recoveryDelays = [0, 0, 0]
            playback.playbackStarted()
            playback.playbackFailed(detail: "Synthetic failure")
            try await eventually { server.captured.filter { $0.path == "/api/playback/resolve" }.count >= 2 }
            _ = await playback.stop()
        }
        XCTAssertEqual(PlaybackModel.retryWait(after: PigTVError.serverMessage("The provider did not respond in time.", status: 500)), 0)
        XCTAssertNil(PlaybackModel.retryWait(after: PigTVError.serverMessage("The provider refused this channel (HTTP 403).", status: 404)))
    }

    /// #153: a channel the provider no longer has (its 404, sent wrapped in HTTP 500) is not retried: the viewer sees why at once.
    func testAMissingChannelIsNotRetriedThoughSentAs500() async throws {
        let server = SyntheticServer { _, _, _ in
            .init(status: 500, json: #"{"error":"This channel is not available from the provider (HTTP 404). It may be offline or have moved; a playlist sync may help."}"#)
        }
        let playback = model(try client(server))
        playback.recoveryDelays = [0, 0, 0]
        playback.playbackStarted()
        playback.playbackFailed(detail: "Synthetic failure")
        try await eventually { playback.error != nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.captured.filter { $0.path == "/api/playback/resolve" }.count, 1, "a missing channel is not retried")
        _ = await playback.stop()
        for lasting in ["This channel is not available. It may have been removed from the playlist; a playlist sync may help.",
                        "This channel is not available: the playlist has no stream address for it."] {
            XCTAssertNil(PlaybackModel.retryWait(after: PigTVError.serverMessage(lasting, status: 500)), lasting)
        }
        for passing in ["This channel is not available right now: its stream could not be opened. Try again in a few seconds.",
                        "The provider refused this channel (HTTP 502): its server had a problem. Try again in a few seconds.",
                        "The provider did not respond (connection refused). Its server may be down; try again shortly."] {
            XCTAssertEqual(PlaybackModel.retryWait(after: PigTVError.serverMessage(passing, status: 500)), 0, passing)
        }
    }

    /// #139: a 429 is retried no sooner than its retry-after.
    func testARateLimitedReconnectWaitsItsRetryAfter() async throws {
        let times = Locked<[Date]>([])
        let server = SyntheticServer { _, _, count in
            times.value.append(Date())
            return count == 1 ? .init(status: 429, json: #"{"error":"slow down","retryAfterSec":1}"#) : .init(status: 503, json: "{}")
        }
        let playback = model(try client(server))
        playback.recoveryDelays = [0, 0, 0]
        playback.playbackStarted()
        playback.playbackFailed(detail: "Synthetic failure")
        for _ in 0..<150 where server.captured.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let t = times.value
        XCTAssertGreaterThanOrEqual(t.count, 2)
        XCTAssertGreaterThanOrEqual(t[1].timeIntervalSince(t[0]), 0.95, "the retry waited for the server's retry-after")
        _ = await playback.stop()
    }

    /// #140: when the old session could not be released, the next recovery still asks whether it was taken over,
    /// and a takeover stops it instead of resolving again.
    func testARetryAfterAFailedReleaseStillChecksForATakeover() async throws {
        let server = SyntheticServer { path, method, count in
            switch (method, path) {
            case ("POST", "/api/playback/resolve"):
                return count == 1 ? .init(status: 200, json: #"{"strategy":"transcode","url":"/api/transcode/s1/master.m3u8","sessionId":"s1","container":"hls"}"#)
                    : .init(status: 503, json: "{}")
            case ("DELETE", "/api/playback/s1"):
                return count <= 2 ? .init(status: 500, json: "{}") : .init(status: 200, json: #"{"success":true}"#)
            case ("GET", "/api/playback/s1/terminal-status"):
                return .init(status: 200, json: count == 1 ? #"{"status":"none"}"# : #"{"status":"taken-over"}"#)
            default:
                return .init(status: 404, json: "{}")
            }
        }
        let playback = model(try client(server, modern: true))
        playback.recoveryDelays = [0, 0.2, 0.2]
        playback.start()
        try await eventually { playback.ready }
        playback.playbackStarted()
        playback.playbackFailed(detail: "Synthetic failure")
        try await eventually { playback.error == "Playback moved to another device." }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(server.captured.filter { $0.path == "/api/playback/resolve" }.count, 1, "no resolve after the takeover")
        _ = await playback.stop()
    }

    /// #5: the re-resolves are spaced 0 / 3 / 10 s (scaled down here), with the Reconnecting card meanwhile.
    func testReResolvesAreSpacedOut() async throws {
        let times = Locked<[Date]>([])
        let server = SyntheticServer { _, _, _ in times.value.append(Date()); return .init(status: 503, json: "{}") }
        let playback = model(try client(server))
        playback.recoveryDelays = [0, 0.3, 0.6]
        playback.playbackStarted()
        let began = Date()
        playback.playbackFailed(detail: "Synthetic failure")
        try await eventually { server.captured.count == 2 }
        XCTAssertTrue(playback.reconnecting)
        XCTAssertNil(playback.error)
        for _ in 0..<100 where playback.error == nil { try await Task.sleep(for: .milliseconds(20)) }
        let t = times.value
        XCTAssertEqual(t.count, 3)
        XCTAssertLessThan(t[0].timeIntervalSince(began), 0.25, "the first re-resolve is immediate")
        XCTAssertGreaterThanOrEqual(t[1].timeIntervalSince(t[0]), 0.3)
        XCTAssertGreaterThanOrEqual(t[2].timeIntervalSince(t[1]), 0.6)
        XCTAssertNotNil(playback.error)
        _ = await playback.stop()
    }

    /// #5: going Back during the wait before a re-resolve issues nothing.
    func testStoppingDuringTheRecoveryWaitPreventsResolve() async throws {
        let server = SyntheticServer { _, _, _ in .init(status: 503, json: "{}") }
        let playback = model(try client(server))
        playback.recoveryDelays = [0, 0.3, 0.3]
        playback.playbackStarted()
        playback.playbackFailed(detail: "Synthetic failure")
        try await eventually { server.captured.count == 1 }
        _ = await playback.stop()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(server.captured.count, 1)
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

    // Build 27: the item is installed and played as soon as the resolve
    // answers; the display mode comes from the decision, not an asset load
    // (which on the device held every start for ~3 s).
    func testStartInstallsTheItemWithoutWaitingForDisplayCriteria() async throws {
        let server = SyntheticServer { path, _, _ in
            if path == "/api/playback/resolve" {
                return .init(status: 200, json: #"{"strategy":"transcode","url":"/api/transcode/s1/master.m3u8","sessionId":"s1","container":"hls","videoMode":"copy","info":{"fps":"50/1","videoRange":"PQ","video":"hevc","width":3840,"height":2160}}"#)
            }
            return .init(status: 200, json: #"{"success":true}"#)
        }
        let playback = model(try client(server))
        var installedAt: Date?
        let watch = playback.$ready.sink { if $0, installedAt == nil { installedAt = Date() } }
        let began = Date()
        playback.start()
        try await eventually { installedAt != nil }
        XCTAssertLessThan(installedAt!.timeIntervalSince(began), 1.5)
        #if os(tvOS)
        XCTAssertNotNil(playback.displayCriteria)
        #endif
        watch.cancel()
        _ = await playback.stop()
    }

    // Build 27 fallbacks. The media host is an unanswered documentation
    // address (TEST-NET-1), so the real player item stays loading and only
    // the synthetic failures below drive the model.
    private let quietHost = "https://192.0.2.1"

    private func itemPath(_ playback: PlaybackModel) -> String? {
        (playback.player.currentItem?.asset as? AVURLAsset)?.url.path
    }
    private func itemQuery(_ playback: PlaybackModel) -> String? {
        (playback.player.currentItem?.asset as? AVURLAsset)?.url.query
    }

    func testNoCompatibleAlternatesPlaysTheStreamPlaylistOnce() async throws {
        let server = SyntheticServer { path, _, _ in
            if path == "/api/playback/resolve" {
                return .init(status: 200, json: #"{"strategy":"transcode","url":"/api/transcode/s1/master.m3u8","sessionId":"s1","container":"hls","videoMode":"copy","info":{"fps":"50/1","videoRange":"PQ"}}"#)
            }
            return .init(status: 200, json: #"{"success":true}"#)
        }
        let playback = model(try client(server, address: quietHost))
        playback.start()
        try await eventually { playback.player.currentItem != nil }
        XCTAssertEqual(itemPath(playback), "/api/transcode/s1/master.m3u8")
        let noAlternates = [PlayerErrorCode(domain: AVFoundationErrorDomain, code: -11868)]
        playback.playbackFailed(detail: "Synthetic", codeName: AVFoundationErrorDomain, code: -11868, errorCodes: noAlternates)
        XCTAssertEqual(itemPath(playback), "/api/transcode/s1/stream.m3u8", "the same session's media playlist")
        XCTAssertEqual(itemQuery(playback), "token=fixture")
        XCTAssertTrue(playback.ready)
        XCTAssertNil(playback.error)
        #if os(tvOS)
        XCTAssertNil(playback.displayCriteria, "no display criteria for the fallback")
        #endif
        // A second failure is not retried again and resolves nothing.
        playback.playbackFailed(detail: "Synthetic", codeName: AVFoundationErrorDomain, code: -11868, errorCodes: noAlternates)
        XCTAssertNotNil(playback.error)
        XCTAssertTrue(playback.canRetry)
        try await Task.sleep(for: .milliseconds(50))
        // The player's conflict poll may get one request out before the failure stops it; it resolves nothing.
        XCTAssertEqual(server.captured.map(\.path).filter { $0 != "/api/playback/conflict" }, ["/api/playback/resolve"])
        _ = await playback.stop()
    }

    func testUnsupportedAudioFormatResolvesOnceWithAudioEncodeAndRemembers() async throws {
        let channelKey = "1:42"
        var remembered = UserDefaults.standard.stringArray(forKey: AudioEncodeMemory.key) ?? []
        remembered.removeAll { $0 == channelKey }
        UserDefaults.standard.set(remembered, forKey: AudioEncodeMemory.key)
        defer {
            let left = (UserDefaults.standard.stringArray(forKey: AudioEncodeMemory.key) ?? []).filter { $0 != channelKey }
            UserDefaults.standard.set(left, forKey: AudioEncodeMemory.key)
        }
        let server = SyntheticServer { path, _, count in
            if path == "/api/playback/resolve" {
                return .init(status: 200, json: #"{"strategy":"transcode","url":"/api/transcode/s\#(count)/stream.m3u8","sessionId":"s\#(count)","container":"hls","videoMode":"copy"}"#)
            }
            return .init(status: 200, json: #"{"success":true}"#)
        }
        let playback = model(try client(server, address: quietHost))
        playback.start()
        try await eventually { playback.player.currentItem != nil }
        let fmt = [PlayerErrorCode(domain: "CoreMediaErrorDomain", code: 1718449215)]
        playback.playbackFailed(detail: "Synthetic", codeName: "PlayerError", code: 1718449215, errorCodes: fmt)
        try await eventually { itemPath(playback) == "/api/transcode/s2/stream.m3u8" }
        let resolves = server.captured.filter { $0.path == "/api/playback/resolve" }
        XCTAssertEqual(resolves.count, 2)
        let first = try JSONSerialization.jsonObject(with: resolves[0].body) as! [String: Any]
        let second = try JSONSerialization.jsonObject(with: resolves[1].body) as! [String: Any]
        XCTAssertNil(first["audioEncode"])
        XCTAssertEqual(second["audioEncode"] as? Bool, true)
        XCTAssertEqual(second["force"] as? Bool, false, "a fallback never forces")
        XCTAssertTrue(server.captured.contains { $0.path == "/api/playback/s1" && $0.method == "DELETE" }, "the failed session is released first")
        XCTAssertTrue(AudioEncodeMemory.contains(channelKey))
        // The same error again: no third resolve.
        playback.playbackFailed(detail: "Synthetic", codeName: "PlayerError", code: 1718449215, errorCodes: fmt)
        XCTAssertNotNil(playback.error)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(server.captured.filter { $0.path == "/api/playback/resolve" }.count, 2)
        _ = await playback.stop()

        // A later play of the channel asks for audioEncode straight away.
        let later = model(try client(server, address: quietHost))
        later.start()
        try await eventually { server.captured.filter { $0.path == "/api/playback/resolve" }.count == 3 }
        let third = try JSONSerialization.jsonObject(with: server.captured.filter { $0.path == "/api/playback/resolve" }[2].body) as! [String: Any]
        XCTAssertEqual(third["audioEncode"] as? Bool, true)
        _ = await later.stop()
    }

    func testFallbackClassificationAndStreamURL() {
        XCTAssertEqual(PlaybackFallback.for([PlayerErrorCode(domain: AVFoundationErrorDomain, code: -11868)]), .streamPlaylist)
        XCTAssertEqual(PlaybackFallback.for([PlayerErrorCode(domain: AVFoundationErrorDomain, code: -11800),
                                             PlayerErrorCode(domain: NSOSStatusErrorDomain, code: 1718449215)]), .audioEncode)
        XCTAssertNil(PlaybackFallback.for([PlayerErrorCode(domain: NSURLErrorDomain, code: -11868)]))
        XCTAssertNil(PlaybackFallback.for([PlayerErrorCode(domain: AVFoundationErrorDomain, code: -11800)]))
        XCTAssertNil(PlaybackFallback.for([]))
        let master = URL(string: "http://tv.lan:3000/api/transcode/abc/master.m3u8?token=a%2Bb")!
        XCTAssertEqual(PlaybackModel.streamPlaylistURL(for: master)?.absoluteString, "http://tv.lan:3000/api/transcode/abc/stream.m3u8?token=a%2Bb")
        XCTAssertNil(PlaybackModel.streamPlaylistURL(for: URL(string: "http://tv.lan/api/transcode/abc/stream.m3u8")!))
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

    // A1.2: "Last channel" memory. switchPlayback only ever builds
    // PlaybackModels and stops the outgoing one (never-started, so no
    // network call), so a plain client with no synthetic server is enough.
    func testAppModelRemembersPreviousChannelAndCanReturnToIt() throws {
        let saved = UserDefaults.standard.data(forKey: LastWatched.key)
        defer { UserDefaults.standard.set(saved, forKey: LastWatched.key) }
        let app = AppModel()
        app.configureClientForTesting(try client(SyntheticServer { _, _, _ in .init(status: 200, json: "{}") }))
        let a = Channel(rawID: "a", sourceId: 1, name: "A", logo: nil, category: nil, now: nil, next: nil)
        let b = Channel(rawID: "b", sourceId: 1, name: "B", logo: nil, category: nil, now: nil, next: nil)
        let c = Channel(rawID: "c", sourceId: 1, name: "C", logo: nil, category: nil, now: nil, next: nil)
        app.beginPlayback(a)
        XCTAssertNil(app.previousChannel, "No previous channel until a switch happens")
        app.switchPlayback(to: b)
        XCTAssertEqual(app.previousChannel?.id, a.id)
        XCTAssertEqual(app.playback?.channel.id, b.id)
        app.switchPlayback(to: c)
        XCTAssertEqual(app.previousChannel?.id, b.id, "The memory tracks the most recent switch, not the original channel")
        app.returnToPreviousChannel()
        XCTAssertEqual(app.playback?.channel.id, b.id, "Returning swaps back to the remembered channel")
        XCTAssertEqual(app.previousChannel?.id, c.id, "Returning is itself a switch, so it updates the memory in turn")
        // Home (build 28): the last channel played is remembered across launches.
        XCTAssertEqual(app.lastWatched?.id, b.id)
        XCTAssertEqual(LastWatched.load()?.id, b.id)
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

    // Test block 1.9: starting a channel crashed with -[AVPlayerItem
    // setExternalMetadata:] unrecognized selector once AVKit was no longer
    // loaded on tvOS. Setting metadata must never crash, whether or not AVKit
    // provides the property.
    func testSettingExternalMetadataNeverCrashes() {
        let item = AVPlayerItem(url: URL(string: "http://127.0.0.1:1/master.m3u8")!)
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = "Test" as NSString
        PlaybackModel.setExternalMetadata([title], on: item)
    }

    #if os(tvOS)
    // The TV switches display mode through UIWindow.avDisplayManager, an AVKit
    // category. If AVKit stops being loaded, that call crashes at channel start.
    func testAVKitCategoriesAreAvailableOnTV() {
        XCTAssertTrue(UIWindow.instancesRespond(to: NSSelectorFromString("avDisplayManager")),
                      "AVKit is not loaded: display-mode switching would crash")
        XCTAssertTrue(AVPlayerItem.instancesRespond(to: NSSelectorFromString("setExternalMetadata:")))
    }
    #endif
}
