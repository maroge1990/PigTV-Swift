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
    private var savedLastWatched: Data?

    override func setUp() async throws {
        try await super.setUp()
        // AppModel remembers played channels for Home; keep the host's own.
        savedLastWatched = UserDefaults.standard.data(forKey: LastWatched.key)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedLastWatched, forKey: LastWatched.key)
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

    private func harnessRecording() throws -> Recording {
        try JSONDecoder().decode(Recording.self, from: Data(#"{"id":4242,"title":"Harness","status":"completed","duration_sec":6}"#.utf8))
    }

    private static let oneBreak = #"{"status":"completed","markers":[{"id":1,"startMs":1000,"endMs":2000,"type":"ad"}]}"#

    /// Audit R07: a markers request that takes 10 s must not delay the picture,
    /// and once the 3 s budget is spent there are simply no breaks.
    func testRecordingStartsWhileMarkersAreStillHanging() async throws {
        try requireFixture()
        let server = try FakePigTVServer(markers: .init(status: 200, contentType: "application/json",
                                                        body: Data(Self.oneBreak.utf8), delay: 10))
        UserDefaults.standard.removeObject(forKey: "pigtv.resume.4242")
        defer { UserDefaults.standard.removeObject(forKey: "pigtv.resume.4242") }
        let playback = RecordingPlayerModel(recording: try harnessRecording(), client: try server.client())
        let began = Date()
        playback.start()
        try await waitFor("the recording to play", timeout: 6) { playback.hasPlayed }
        let toPlay = Date().timeIntervalSince(began)
        print("R07 timing: playing after \(String(format: "%.2f", toPlay)) s with markers delayed 10 s")
        XCTAssertLessThan(toPlay, 3, "markers held the picture back")
        XCTAssertTrue(playback.ready)
        XCTAssertTrue(playback.breaks.isEmpty)
        try await Task.sleep(for: .seconds(3.5))
        XCTAssertTrue(playback.breaks.isEmpty, "markers past the budget are ignored")
        XCTAssertNil(playback.error)
        await playback.stop()
        server.http.stop()
    }

    /// Markers that arrive after playback began are still applied.
    func testLateMarkersAreStillApplied() async throws {
        try requireFixture()
        let server = try FakePigTVServer(markers: .init(status: 200, contentType: "application/json",
                                                        body: Data(Self.oneBreak.utf8), delay: 2))
        UserDefaults.standard.removeObject(forKey: "pigtv.resume.4242")
        defer { UserDefaults.standard.removeObject(forKey: "pigtv.resume.4242") }
        let playback = RecordingPlayerModel(recording: try harnessRecording(), client: try server.client())
        playback.autoSkip = false
        let began = Date()
        playback.start()
        try await waitFor("the recording to play") { playback.hasPlayed }
        let toPlay = Date().timeIntervalSince(began)
        print("R07 timing: playing after \(String(format: "%.2f", toPlay)) s with markers delayed 2 s")
        XCTAssertLessThan(toPlay, 2, "playback waited for the markers")
        XCTAssertTrue(playback.breaks.isEmpty, "markers cannot have arrived yet")
        try await waitFor("the late markers", timeout: 6) { playback.breaks.count == 1 }
        await playback.stop()
        server.http.stop()
    }

    /// A failing markers endpoint still plays, with no breaks.
    func testRecordingPlaysWhenMarkersFail() async throws {
        try requireFixture()
        let server = try FakePigTVServer(markers: .json(#"{"error":"boom"}"#, status: 500))
        UserDefaults.standard.removeObject(forKey: "pigtv.resume.4242")
        defer { UserDefaults.standard.removeObject(forKey: "pigtv.resume.4242") }
        let playback = RecordingPlayerModel(recording: try harnessRecording(), client: try server.client())
        playback.start()
        try await waitFor("the recording to play") { playback.hasPlayed }
        XCTAssertTrue(playback.breaks.isEmpty)
        XCTAssertNil(playback.error)
        await playback.stop()
        server.http.stop()
    }

    /// Cancelling (Back) before the markers arrive installs nothing late.
    func testStopBeforeMarkersArriveInstallsNothing() async throws {
        try requireFixture()
        let server = try FakePigTVServer(markers: .init(status: 200, contentType: "application/json",
                                                        body: Data(Self.oneBreak.utf8), delay: 1))
        UserDefaults.standard.removeObject(forKey: "pigtv.resume.4242")
        defer { UserDefaults.standard.removeObject(forKey: "pigtv.resume.4242") }
        let playback = RecordingPlayerModel(recording: try harnessRecording(), client: try server.client())
        playback.start()
        await playback.stop()
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(playback.breaks.isEmpty)
        XCTAssertNil(playback.player.currentItem)
        XCTAssertFalse(playback.ready)
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
        try await waitFor("the break markers") { playback.breaks.count == 1 }
        XCTAssertTrue(playback.hasPlayed)
        try await waitFor("the periodic observer to see the break") { playback.inBreak != nil }
        XCTAssertNotNil(playback.timeline())
        XCTAssertNil(playback.error)
        await playback.stop()
        XCTAssertNil(playback.player.currentItem)
        server.http.stop()
    }

    /// C-I: selecting a sport event plays its best channel (the first in
    /// `channels`) with the event's channels as the zap list, for real.
    func testSelectingASportEventPlaysItsBestChannel() async throws {
        try requireFixture()
        let server = try FakePigTVServer()
        let client = try server.client()
        let browse = BrowseModel(client: client)
        let app = AppModel()
        app.configureClientForTesting(client, browse: browse)
        await browse.sport.load()
        let event = try XCTUnwrap(browse.sport.live.first)
        channelKeys += event.channels.map { browse.playable($0).identityKey }
        app.playSportEvent(event)
        let playback = try XCTUnwrap(app.playback)
        XCTAssertEqual(playback.channel.id, "1:701")
        XCTAssertEqual(app.zapList.map(\.id), ["1:701", "1:702", "2:88"])
        playback.start()
        try await waitFor("the best channel playing") { isPlaying(playback) }
        let body = try XCTUnwrap(server.resolveBodies().first)
        XCTAssertEqual(body["channelId"] as? String, "701")
        XCTAssertEqual(body["sourceId"] as? Int, 1)
        XCTAssertEqual(body["force"] as? Bool, false)
        XCTAssertEqual(itemPath(playback), "/api/transcode/s1/master.m3u8")
        XCTAssertNil(playback.error)
        await app.endPlayback(playback)
        server.http.stop()
    }

    /// R11: with warming on, a live Sport event that holds focus warms its best
    /// channel with exactly the body resolve sends; playing it then adopts the
    /// warm stream, and the play-start event carries `warm`. While watching,
    /// the next channel up is warmed too, and none of it happens with the
    /// setting off.
    func testFocusedSportEventWarmsThenPlayAdoptsIt() async throws {
        try requireFixture()
        let server = try FakePigTVServer(warm: .json(#"{"warm":true,"ttlSec":90,"refreshed":false}"#))
        let client = try server.client(warmingEnabled: true)
        let browse = BrowseModel(client: client)
        let app = AppModel()
        app.configureClientForTesting(client, browse: browse)
        await browse.sport.load()
        let event = try XCTUnwrap(browse.sport.live.first)
        channelKeys += event.channels.map { browse.playable($0).identityKey }

        // Focus churn first: three cards in quick succession send nothing.
        let target = try XCTUnwrap(SportWarming.target(eventID: event.id, in: browse.sport.live, now: Date()))
        app.warmer.setBrowseTarget(WarmTarget(sourceId: 9, channelId: "x", identityKey: "9:x"), owner: "shelf")
        try await Task.sleep(for: .milliseconds(300))
        app.warmer.setBrowseTarget(target, owner: "shelf")
        try await waitFor("the warm request after the dwell") { server.warms.count == 1 }
        let warmBody = try XCTUnwrap(server.warmBodies().first)
        XCTAssertEqual(warmBody["channelId"] as? String, "701")
        XCTAssertEqual(warmBody["sourceId"] as? Int, 1)
        XCTAssertEqual(warmBody["force"] as? Bool, false)
        XCTAssertNil(warmBody["audioEncode"])
        XCTAssertTrue(server.resolves.isEmpty, "warming is not resolving")

        app.playSportEvent(event)
        let playback = try XCTUnwrap(app.playback)
        playback.start()
        try await waitFor("the best channel playing") { isPlaying(playback) }
        let resolveBody = try XCTUnwrap(server.resolveBodies().first)
        XCTAssertEqual(NSDictionary(dictionary: resolveBody), NSDictionary(dictionary: warmBody),
                       "the warm request is the body resolve would send")
        XCTAssertTrue(playback.warmAdopted, "the decision was marked warm")
        try await waitFor("play-start") { !server.clientEventBodies("play-start").isEmpty }
        XCTAssertEqual(server.clientEventBodies("play-start").first?["warm"] as? Bool, true)

        // Watching 701: the next one up (702) is warmed after the dwell, once the start is over.
        try await waitFor("the next channel warmed") { server.warmBodies().contains { $0["channelId"] as? String == "702" } }
        XCTAssertEqual(server.warms.count, 2)
        await app.endPlayback(playback)
        server.http.stop()
    }

    /// R11: the setting off (or an older server) means no warm request, ever.
    func testNothingIsWarmedWithTheSettingOff() async throws {
        let server = try FakePigTVServer(warm: .json(#"{"warm":true}"#))
        let client = try server.client(warmingEnabled: false)
        let browse = BrowseModel(client: client)
        let app = AppModel()
        app.configureClientForTesting(client, browse: browse)
        await browse.sport.load()
        let event = try XCTUnwrap(browse.sport.live.first)
        let target = try XCTUnwrap(SportWarming.target(eventID: event.id, in: browse.sport.live, now: Date()))
        app.warmer.setBrowseTarget(target, owner: "shelf")
        try await Task.sleep(for: .seconds(2.2))
        XCTAssertTrue(server.warms.isEmpty)
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
