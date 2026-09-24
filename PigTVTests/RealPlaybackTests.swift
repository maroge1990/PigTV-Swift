import XCTest
import AVFoundation
@testable import PigTV

/// Real playback through the app's own code (build 28). Two crashes reached
/// the TV because no test ever played a stream: the AVKit `externalMetadata`
/// category (builds 21–23) and, before it, the display-criteria wait. Here a
/// real PlaybackModel resolves against FakePigTVServer (a socket on
/// 127.0.0.1) and AVPlayer plays the bundled HLS fixture, so item creation,
/// metadata, display criteria, the KVO status/timeControlStatus observers,
/// the notification observers, client events and release all run for real.
@MainActor
final class RealPlaybackTests: XCTestCase {
    private var channelKeys: [String] = []

    override func tearDown() async throws {
        // Leave no audio-encode memory behind for the harness channels.
        let left = (UserDefaults.standard.stringArray(forKey: AudioEncodeMemory.key) ?? []).filter { !channelKeys.contains($0) }
        UserDefaults.standard.set(left, forKey: AudioEncodeMemory.key)
        channelKeys = []
        try await super.tearDown()
    }

    private func channel() -> Channel {
        let id = "harness-\(UUID().uuidString.prefix(8))"
        let channel = Channel(rawID: id, sourceId: 1, name: "Harness", logo: nil, category: nil, now: nil, next: nil)
        channelKeys.append(channel.identityKey)
        return channel
    }

    private func programmes() -> [GuideProgramme] {
        let now = Date().timeIntervalSince1970 * 1000
        return [GuideProgramme(title: "Test Card", description: "The fixture.", startTime: now - 600_000, endTime: now + 600_000),
                GuideProgramme(title: "Next Up", description: nil, startTime: now + 600_000, endTime: now + 1_800_000)]
    }

    private func requireFixture() throws {
        guard HLSFixture.isComplete else {
            XCTFail("The HLS fixture is missing from the test bundle: \(HLSFixture.files.filter { HLSFixture.contents[$0] == nil })")
            throw XCTSkip("no fixture")
        }
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out after \(timeout) s waiting for \(what)", file: file, line: line)
        throw XCTSkip("timed out")
    }

    private func itemPath(_ playback: PlaybackModel) -> String? {
        (playback.player.currentItem?.asset as? AVURLAsset)?.url.path
    }

    private func isPlaying(_ playback: PlaybackModel) -> Bool {
        playback.player.timeControlStatus == .playing && playback.player.currentItem?.status == .readyToPlay
    }

    func testFixtureIsServedOverTheLocalSocket() async throws {
        try requireFixture()
        let server = try FakePigTVServer()
        let url = URL(string: server.http.baseURL + "/api/transcode/s1/master.m3u8?token=fixture")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("FRAME-RATE=25.000"))
        XCTAssertTrue(text.contains("VIDEO-RANGE=SDR"))
        var ranged = URLRequest(url: URL(string: server.http.baseURL + "/api/transcode/s1/fixture-seg0.m4s")!)
        ranged.setValue("bytes=0-99", forHTTPHeaderField: "Range")
        let (part, partial) = try await URLSession.shared.data(for: ranged)
        XCTAssertEqual((partial as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(part.count, 100)
        server.http.stop()
    }

    /// The whole live start: resolve → item → ready → AVPlayer actually
    /// playing → play-start event → stop releases the session.
    func testLiveChannelReallyPlays() async throws {
        try requireFixture()
        let server = try FakePigTVServer()
        let playback = PlaybackModel(channel: channel(), client: try server.client(), programmes: programmes())
        let began = Date()
        playback.start()
        try await waitFor("ready") { playback.ready }
        XCTAssertLessThan(Date().timeIntervalSince(began), 3, "nothing may wait before the item is installed")
        XCTAssertEqual(itemPath(playback), "/api/transcode/s1/master.m3u8")
        #if os(tvOS)
        XCTAssertNotNil(playback.displayCriteria, "criteria come from the resolve decision's fps")
        #endif
        try await waitFor("AVPlayer .playing") { isPlaying(playback) }
        try await waitFor("the picture's clock to move") { playback.player.currentTime().seconds > 0.5 }
        XCTAssertNil(playback.error)
        // The timeControlStatus KVO observer fired and reported the start.
        try await waitFor("play-start event") { server.clientEvents().contains("play-start") }
        let body = try XCTUnwrap(server.resolveBodies().first)
        XCTAssertEqual(body["force"] as? Bool, false)
        XCTAssertNil(body["audioEncode"])
        let warning = await playback.stop()
        XCTAssertNil(warning)
        XCTAssertNil(playback.player.currentItem)
        XCTAssertEqual(server.http.requests(path: "/api/playback/s1", method: "DELETE").count, 1, "the session is released")
        server.http.stop()
    }

    /// A decision without a usable frame rate: the asset's display criteria
    /// load in the background (the build 27 path), and playback never waits.
    func testPlaysWithoutFrameRateInTheDecision() async throws {
        try requireFixture()
        let server = try FakePigTVServer { count, _ in FakePigTVServer.decision(session: "s\(count)", playlist: "stream.m3u8", fps: nil) }
        let playback = PlaybackModel(channel: channel(), client: try server.client())
        playback.start()
        try await waitFor("AVPlayer .playing") { isPlaying(playback) }
        XCTAssertEqual(itemPath(playback), "/api/transcode/s1/stream.m3u8")
        XCTAssertNil(playback.error)
        _ = await playback.stop()
        server.http.stop()
    }

    /// -11868 (no compatible alternates): a VIDEO-RANGE=PQ master on a
    /// display that cannot show it. When the simulator refuses the PQ variant,
    /// the model must fall back to the same session's stream.m3u8 and play.
    /// Skipped when this simulator plays the PQ variant anyway.
    func testNoCompatibleAlternatesFallsBackToTheStreamPlaylist() async throws {
        try requireFixture()
        let server = try FakePigTVServer { count, _ in FakePigTVServer.decision(session: "pq\(count)", videoRange: "PQ") }
        let playback = PlaybackModel(channel: channel(), client: try server.client())
        playback.start()
        try await waitFor("ready") { playback.ready }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !isPlaying(playback), playback.error == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        if itemPath(playback) == "/api/transcode/pq1/master.m3u8", isPlaying(playback) {
            _ = await playback.stop()
            server.http.stop()
            throw XCTSkip("This simulator plays the PQ variant, so -11868 cannot be triggered here.")
        }
        XCTAssertNil(playback.error, "the fallback should have recovered: \(playback.error ?? "")")
        XCTAssertEqual(itemPath(playback), "/api/transcode/pq1/stream.m3u8")
        try await waitFor("AVPlayer .playing on stream.m3u8") { isPlaying(playback) }
        XCTAssertEqual(server.resolves.count, 1, "the fallback needs no new resolve")
        // It really was -11868, reported by the item's status KVO observer.
        let errors = server.http.requests(path: "/api/playback/client-event", method: "POST")
            .compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
            .filter { $0["event"] as? String == "media-error" }
        XCTAssertEqual(errors.first?["code"] as? Int, PlaybackFallback.noCompatibleAlternates)
        _ = await playback.stop()
        server.http.stop()
    }

    /// 'fmt?' (copied audio the device cannot decode) cannot be produced by
    /// this fixture, so the failure is synthetic; everything after it is real:
    /// release, a second resolve with audioEncode, a real item that plays.
    func testAudioEncodeFallbackResolvesAgainAndPlays() async throws {
        try requireFixture()
        let server = try FakePigTVServer()
        let channel = channel()
        let playback = PlaybackModel(channel: channel, client: try server.client())
        playback.start()
        try await waitFor("first stream playing") { isPlaying(playback) }
        let fmt = [PlayerErrorCode(domain: AVFoundationErrorDomain, code: -11800),
                   PlayerErrorCode(domain: NSOSStatusErrorDomain, code: PlaybackFallback.unsupportedAudioFormat)]
        playback.playbackFailed(detail: "Synthetic 'fmt?'", codeName: AVFoundationErrorDomain, code: -11800, errorCodes: fmt)
        try await waitFor("second resolve") { server.resolves.count == 2 }
        let bodies = server.resolveBodies()
        XCTAssertNil(bodies[0]["audioEncode"])
        XCTAssertEqual(bodies[1]["audioEncode"] as? Bool, true)
        XCTAssertEqual(bodies[1]["force"] as? Bool, false)
        XCTAssertEqual(server.http.requests(path: "/api/playback/s1", method: "DELETE").count, 1, "the failed session is released first")
        try await waitFor("second stream playing") { itemPath(playback) == "/api/transcode/s2/master.m3u8" && isPlaying(playback) }
        XCTAssertNil(playback.error)
        XCTAssertTrue(AudioEncodeMemory.contains(channel.identityKey))
        _ = await playback.stop()
        server.http.stop()
    }

    /// A recording (C-E HLS answer) through RecordingPlayerModel: the item
    /// status KVO observer and the periodic time observer (main queue,
    /// MainActor.assumeIsolated) both run; the time observer notices the
    /// fixture's 1–2 s ad break.
    func testRecordingReallyPlaysAndTheTimeObserverTicks() async throws {
        try requireFixture()
        let server = try FakePigTVServer()
        let recording = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":4242,"title":"Harness","status":"completed","duration_sec":6}"#.utf8))
        let autoSkip = UserDefaults.standard.object(forKey: "pigtv.recordings.autoSkip")
        UserDefaults.standard.removeObject(forKey: "pigtv.resume.4242")
        defer {
            UserDefaults.standard.removeObject(forKey: "pigtv.resume.4242")
            UserDefaults.standard.set(autoSkip, forKey: "pigtv.recordings.autoSkip")
        }
        let playback = RecordingPlayerModel(recording: recording, client: try server.client())
        playback.autoSkip = false
        playback.start()
        try await waitFor("recording ready") { playback.ready }
        try await waitFor("recording playing") {
            playback.player.timeControlStatus == .playing && playback.player.currentItem?.status == .readyToPlay
        }
        XCTAssertEqual(playback.breaks.count, 1)
        try await waitFor("the periodic observer to see the break") { playback.inBreak != nil }
        XCTAssertNotNil(playback.timeline())
        XCTAssertNil(playback.error)
        await playback.stop()
        XCTAssertNil(playback.player.currentItem)
        server.http.stop()
    }

    /// Channel switching as the app does it: the old model is stopped (and
    /// its session released) before the new one resolves, and the new one
    /// really plays.
    func testSwitchingChannelsReleasesThenPlaysTheNext() async throws {
        try requireFixture()
        let server = try FakePigTVServer()
        let app = AppModel()
        app.configureClientForTesting(try server.client())
        app.beginPlayback(channel())
        let first = try XCTUnwrap(app.playback)
        first.start()
        try await waitFor("first channel playing") { isPlaying(first) }
        app.switchPlayback(to: channel())
        let second = try XCTUnwrap(app.playback)
        XCTAssertFalse(first === second)
        second.start()
        try await waitFor("second channel playing") { isPlaying(second) }
        let order = server.http.requests.map { "\($0.method) \($0.path)" }
        let released = try XCTUnwrap(order.firstIndex(of: "DELETE /api/playback/s1"))
        let resolved = try XCTUnwrap(order.lastIndex(of: "POST /api/playback/resolve"))
        XCTAssertLessThan(released, resolved, "release before the next resolve (one provider stream)")
        await app.endPlayback(second)
        server.http.stop()
    }
}
