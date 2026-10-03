import XCTest
import AVFoundation
@testable import PigTV

/// Build 36 (multi-provider failover, client side): C-J provider on resolve,
/// C-K licence reminders, and the renewed recovery allowance, all against
/// FakePigTVServer.
@MainActor
final class ProviderFailoverTests: XCTestCase {
    private var defaults: UserDefaults!
    private var channelKeys: [String] = []
    private let utc = TimeZone(identifier: "UTC")!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "pigtv.tests.providers")!
        defaults.removePersistentDomain(forName: "pigtv.tests.providers")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: "pigtv.tests.providers")
        try await super.tearDown()
    }

    private func channel() -> Channel {
        let channel = Channel(rawID: "prov-\(UUID().uuidString.prefix(8))", sourceId: 1, name: "Harness",
                              logo: nil, category: nil, now: nil, next: nil)
        channelKeys.append(channel.identityKey)
        return channel
    }

    private func requireFixture() throws {
        guard HLSFixture.isComplete else { XCTFail("HLS fixture missing"); throw XCTSkip("no fixture") }
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Timed out waiting for \(what)", file: file, line: line)
        throw XCTSkip("timed out")
    }

    private func isPlaying(_ playback: PlaybackModel) -> Bool {
        playback.player.timeControlStatus == .playing && playback.player.currentItem?.status == .readyToPlay
    }

    // MARK: C-J

    private static let backup = #"{"id":2,"name":"Trex","role":"backup","via":"backup","failover":true}"#

    func testResolveWithProviderIsShownInStreamInfo() async throws {
        try requireFixture()
        let server = try FakePigTVServer { count, _ in FakePigTVServer.decision(session: "s\(count)", provider: Self.backup) }
        let playback = PlaybackModel(channel: channel(), client: try server.client(extraFeatures: #""providers":true"#))
        playback.start()
        try await waitFor("playing") { self.isPlaying(playback) }
        XCTAssertEqual(playback.provider?.name, "Trex")
        XCTAssertEqual(playback.provider?.failover, true)
        let line = await playback.streamStats().line
        XCTAssertTrue(line.contains("Provider: Trex (backup)"), line)
        XCTAssertTrue(line.contains("switched from primary"), line)
        _ = await playback.stop()
        server.http.stop()
    }

    func testResolveWithoutProviderChangesNothing() async throws {
        try requireFixture()
        let server = try FakePigTVServer()
        let playback = PlaybackModel(channel: channel(), client: try server.client())
        playback.start()
        try await waitFor("playing") { self.isPlaying(playback) }
        XCTAssertNil(playback.provider)
        let line = await playback.streamStats().line
        XCTAssertFalse(line.contains("Provider"), line)
        XCTAssertNil(playback.error)
        _ = await playback.stop()
        server.http.stop()
    }

    func testStreamInfoLineForPrimaryBackupAndFailover() {
        var stats = StreamStats()
        stats.provider = ResolveProvider(id: 1, name: "Strong8K", role: "primary", via: "primary", failover: false)
        XCTAssertFalse(stats.line.contains("Provider"), "the ordinary primary play adds nothing")
        stats.provider = ResolveProvider(id: 1, name: "Strong8K", role: "primary", via: "sibling", failover: true)
        XCTAssertTrue(stats.line.contains("Provider: Strong8K · switched from primary"), stats.line)
        stats.provider = ResolveProvider(id: 2, name: "Trex", role: "backup", via: "backup", failover: false)
        XCTAssertTrue(stats.line.contains("Provider: Trex (backup)"), stats.line)
        XCTAssertFalse(stats.line.contains("switched"), stats.line)
    }

    // MARK: C-K

    private func remindersJSON(name: String = "Trex", expiresAt: Double) -> String {
        #"[{"id":2,"name":"\#(name)","expiresAt":\#(Int64(expiresAt)),"daysLeft":3}]"#
    }

    private func model(clock: Date, autoDismiss: Duration = .seconds(15)) -> (ProviderReminderModel, ClockBox) {
        let box = ClockBox(clock)
        return (ProviderReminderModel(defaults: defaults, clock: { box.now }, timeZone: utc, autoDismiss: autoDismiss), box)
    }

    final class ClockBox { var now: Date; init(_ now: Date) { self.now = now } }

    func testReminderShownOncePerLocalDay() async throws {
        let start = Date(timeIntervalSince1970: 1_774_000_000) // 2026-03-20 09:46 UTC
        let server = try FakePigTVServer(reminders: remindersJSON(expiresAt: start.timeIntervalSince1970 * 1000 + 3 * 86_400_000))
        let client = try server.client(extraFeatures: #""providerReminders":true"#)
        let (reminders, clock) = model(clock: start)
        await reminders.check(client: client, playing: { false })
        let text = try XCTUnwrap(reminders.message)
        XCTAssertTrue(text.hasPrefix("Trex expires "), text)
        XCTAssertTrue(text.hasSuffix("Renew it with the provider; PigTV picks up the new date by itself."), text)
        reminders.dismiss()
        XCTAssertNil(reminders.message)
        // Same day (foreground again): no second popup, and no second request.
        clock.now = start.addingTimeInterval(3600)
        let requests = server.http.requests(path: "/api/providers/reminders", method: "GET").count
        await reminders.check(client: client, playing: { false })
        XCTAssertNil(reminders.message)
        XCTAssertEqual(server.http.requests(path: "/api/providers/reminders", method: "GET").count, requests)
        // A fresh model (a relaunch) shares the device's UserDefaults.
        let (relaunched, _) = model(clock: start.addingTimeInterval(7200))
        await relaunched.check(client: client, playing: { false })
        XCTAssertNil(relaunched.message)
        // The next local day.
        clock.now = start.addingTimeInterval(86_400)
        await reminders.check(client: client, playing: { false })
        XCTAssertNotNil(reminders.message)
        server.http.stop()
    }

    func testReminderNeverShowsDuringPlaybackAndComesAfter() async throws {
        let start = Date(timeIntervalSince1970: 1_774_000_000)
        let server = try FakePigTVServer(reminders: remindersJSON(expiresAt: start.timeIntervalSince1970 * 1000 + 86_400_000))
        let client = try server.client(extraFeatures: #""providerReminders":true"#)
        let (reminders, _) = model(clock: start)
        await reminders.check(client: client, playing: { true })
        XCTAssertNil(reminders.message)
        XCTAssertTrue(server.http.requests(path: "/api/providers/reminders", method: "GET").isEmpty, "nothing is fetched while playing")
        // Playback ends: the deferred check shows it (and it was not used up).
        await reminders.check(client: client, playing: { false })
        XCTAssertNotNil(reminders.message)
        server.http.stop()
    }

    func testReminderHiddenWithoutTheFlagAndWhenNothingIsDue() async throws {
        let start = Date(timeIntervalSince1970: 1_774_000_000)
        let due = remindersJSON(expiresAt: start.timeIntervalSince1970 * 1000)
        let server = try FakePigTVServer(reminders: due)
        let (reminders, _) = model(clock: start)
        await reminders.check(client: try server.client(), playing: { false }) // no flag
        XCTAssertNil(reminders.message)
        XCTAssertTrue(server.http.requests(path: "/api/providers/reminders", method: "GET").isEmpty)
        await reminders.check(client: nil, playing: { false })
        XCTAssertNil(reminders.message)
        server.http.stop()
        // Flag on, empty answer: nothing shown and the day is not used up.
        let empty = try FakePigTVServer(reminders: "[]")
        await reminders.check(client: try empty.client(extraFeatures: #""providerReminders":true"#), playing: { false })
        XCTAssertNil(reminders.message)
        XCTAssertFalse(ProviderReminderSchedule(defaults: defaults).shownToday(now: start, timeZone: utc))
        empty.http.stop()
        // A failing request (404 from the fake) is silent.
        let failing = try FakePigTVServer()
        await reminders.check(client: try failing.client(extraFeatures: #""providerReminders":true"#), playing: { false })
        XCTAssertNil(reminders.message)
        failing.http.stop()
    }

    func testReminderAutoDismissesAndPastExpiryReadsExpired() async throws {
        let start = Date(timeIntervalSince1970: 1_774_000_000)
        let server = try FakePigTVServer(reminders: remindersJSON(expiresAt: start.timeIntervalSince1970 * 1000 - 2 * 86_400_000))
        let (reminders, _) = model(clock: start, autoDismiss: .milliseconds(150))
        await reminders.check(client: try server.client(extraFeatures: #""providerReminders":true"#), playing: { false })
        XCTAssertTrue(try XCTUnwrap(reminders.message).hasPrefix("Trex expired on "))
        try await waitFor("auto-dismiss") { reminders.message == nil }
        server.http.stop()
    }

    // MARK: Recovery allowance

    final class ClockBox2 { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    /// After a recovery, two minutes of good playback renew the allowance:
    /// the backup provider failing later gets one more re-resolve. A failure
    /// within two minutes of a recovery still ends in the error.
    func testRecoveryAllowanceRenewsAfterTwoMinutesOfGoodPlayback() async throws {
        try requireFixture()
        let server = try FakePigTVServer()
        let box = ClockBox2()
        let playback = PlaybackModel(channel: channel(), client: try server.client())
        playback.clock = { box.now }
        playback.start()
        try await waitFor("first stream") { self.isPlaying(playback) }
        // First failure: the ordinary single recovery.
        playback.playbackFailed(detail: "Synthetic 1")
        try await waitFor("second resolve") { server.resolves.count == 2 }
        try await waitFor("second stream") { self.isPlaying(playback) && (playback.player.currentItem?.asset as? AVURLAsset)?.url.path.contains("/s2/") == true }
        // Two minutes of good playback later, another failure: one more re-resolve.
        box.now.addTimeInterval(121)
        playback.playbackFailed(detail: "Synthetic 2")
        try await waitFor("third resolve") { server.resolves.count == 3 }
        XCTAssertNil(playback.error)
        try await waitFor("third stream") { self.isPlaying(playback) && (playback.player.currentItem?.asset as? AVURLAsset)?.url.path.contains("/s3/") == true }
        // A failure only 30 s after that recovery is not renewed: the error.
        box.now.addTimeInterval(30)
        playback.playbackFailed(detail: "Synthetic 3")
        try await waitFor("the error") { playback.error != nil }
        XCTAssertEqual(server.resolves.count, 3, "no retry loop: at most one re-resolve per failure")
        XCTAssertTrue(playback.canRetry)
        _ = await playback.stop()
        server.http.stop()
    }
}
