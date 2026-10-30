import XCTest
@testable import PigTV

/// #13: the player's channel list (and channel up/down) never keeps a one-item or stale list. A play that sets no list
/// of its own (Home's hero, a Top Shelf channel, a programme page's Watch) zaps through the guide; the list a play set
/// ends with it. On build 78 the hero played with a one-channel list, a Top Shelf channel kept the last play's list
/// (a sport event's two channels), and ending playback kept it for the next play.
@MainActor
final class ZapListTests: XCTestCase {
    private func signedIn() throws -> (AppModel, BrowseModel, FakePigTVServer) {
        let server = try FakePigTVServer()
        let app = AppModel()
        app.injectHomeFixture()
        let browse = try XCTUnwrap(app.browse)
        app.configureClientForTesting(try server.client(), browse: browse)
        return (app, browse, server)
    }

    func testEndingAPlayForgetsItsList() async throws {
        let (app, browse, server) = try signedIn()
        defer { server.http.stop() }
        let saved = UserDefaults.standard.data(forKey: LastWatched.key)
        defer { UserDefaults.standard.set(saved, forKey: LastWatched.key) }
        XCTAssertGreaterThan(browse.guide.count, 3)
        let two = browse.guide.prefix(2).map { SportEventChannel(sourceId: $0.sourceId, rawID: $0.rawID, name: $0.name) }
        let now = Date().timeIntervalSince1970 * 1000
        app.playSportEvent(SportEvent(id: "e", title: "Event", league: "AFL", startTime: now - 60_000, endTime: now + 3_600_000, channels: two))
        XCTAssertEqual(app.playerChannels.count, 2, "a sport event zaps through its own channels")
        let playback = try XCTUnwrap(app.playback)
        await app.endPlayback(playback)
        XCTAssertEqual(app.playerChannels.count, browse.guide.count, "the next play that sets no list zaps through the guide")
    }

    func testATopShelfChannelZapsThroughTheGuide() async throws {
        let (app, browse, server) = try signedIn()
        defer { server.http.stop() }
        let saved = UserDefaults.standard.data(forKey: LastWatched.key)
        defer { UserDefaults.standard.set(saved, forKey: LastWatched.key) }
        app.zapList = [browse.asChannel(browse.guide[0])] // left behind by something earlier
        let target = browse.guide[2]
        let delay = AppModel.coverCloseDelay
        AppModel.coverCloseDelay = .milliseconds(10)
        defer { AppModel.coverCloseDelay = delay }
        app.open(try XCTUnwrap(URL(string: "pigtv://play?sourceId=\(target.sourceId)&id=\(target.rawID)")))
        try await Task.sleep(for: .milliseconds(200)) // #14: open pages close first
        XCTAssertEqual(app.playback?.channel.id, browse.asChannel(target).id)
        XCTAssertEqual(app.playerChannels.count, browse.guide.count, "not the one-channel list left behind")
        if let playback = app.playback { await app.endPlayback(playback) }
    }
}

/// #46: Home's minute (and foreground) refresh brings a stale guide up to date; before build 79 only the TV Guide tab
/// did, so Home and the Top Shelf showed yesterday after an overnight resume.
@MainActor
final class HomeGuideRefreshTests: XCTestCase {
    func testHomesRefreshAsksForAStaleGuide() async throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let browse = BrowseModel(client: try server.client())
        browse.guide = GuideFixtures.channels() // loaded, but never stamped: as old as it gets
        await browse.home.refreshNow()
        XCTAssertFalse(server.http.requests(path: "/api/library/guide", method: "GET").isEmpty,
                       "the stale guide is fetched again from Home")
    }
}

/// #14: a play started from outside the screen closes open pages first, and a player that never appears does not
/// leave the app "playing" with no player (every later Watch was refused until the app was killed).
@MainActor
final class PlayOverCoversTests: XCTestCase {
    func testOpenPagesAreAskedToCloseBeforeATopShelfPlay() async throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let app = AppModel()
        app.injectHomeFixture()
        let browse = try XCTUnwrap(app.browse)
        app.configureClientForTesting(try server.client(), browse: browse)
        let saved = UserDefaults.standard.data(forKey: LastWatched.key)
        defer { UserDefaults.standard.set(saved, forKey: LastWatched.key) }
        let delay = AppModel.coverCloseDelay
        AppModel.coverCloseDelay = .milliseconds(50)
        defer { AppModel.coverCloseDelay = delay }
        var closed = 0
        let token = NotificationCenter.default.addObserver(forName: .pigCloseCovers, object: nil, queue: nil) { _ in closed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let target = browse.guide[1]
        app.open(try XCTUnwrap(URL(string: "pigtv://play?sourceId=\(target.sourceId)&id=\(target.rawID)")))
        XCTAssertEqual(closed, 1, "the pages are told to close")
        XCTAssertNil(app.playback, "and the player waits for them")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNotNil(app.playback)
        if let playback = app.playback { await app.endPlayback(playback) }
    }

    func testAPlayerThatNeverAppearsIsGivenUp() async throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let app = AppModel()
        app.injectHomeFixture()
        let browse = try XCTUnwrap(app.browse)
        app.configureClientForTesting(try server.client(), browse: browse)
        let saved = UserDefaults.standard.data(forKey: LastWatched.key)
        defer { UserDefaults.standard.set(saved, forKey: LastWatched.key) }
        let deadline = AppModel.playerAppearDeadline
        AppModel.playerAppearDeadline = .milliseconds(200)
        defer { AppModel.playerAppearDeadline = deadline }
        app.beginPlayback(browse.asChannel(browse.guide[0]))
        XCTAssertTrue(app.playbackBusy)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(app.playback, "no player screen ever appeared: the play is ended")
        XCTAssertFalse(app.playbackBusy, "so a later Watch works")
        XCTAssertEqual(app.error, "The player could not open. Try again.")
        // A play whose screen appears is left alone.
        app.error = nil
        app.beginPlayback(browse.asChannel(browse.guide[1]))
        app.playerAppeared(try XCTUnwrap(app.playback))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNotNil(app.playback)
        if let playback = app.playback { await app.endPlayback(playback) }
    }

    /// #178: a play waiting for pages to close is dropped when the app goes to the background, replaced by a newer
    /// link, and overridden by a play the user starts.
    func testAWaitingPlayIsCancelledOrSuperseded() async throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let app = AppModel()
        app.injectHomeFixture()
        let browse = try XCTUnwrap(app.browse)
        app.configureClientForTesting(try server.client(), browse: browse)
        let saved = UserDefaults.standard.data(forKey: LastWatched.key)
        defer { UserDefaults.standard.set(saved, forKey: LastWatched.key) }
        let delay = AppModel.coverCloseDelay
        AppModel.coverCloseDelay = .milliseconds(150)
        defer { AppModel.coverCloseDelay = delay }
        func link(_ row: GuideChannel) throws -> URL { try XCTUnwrap(URL(string: "pigtv://play?sourceId=\(row.sourceId)&id=\(row.rawID)")) }

        app.open(try link(browse.guide[1]))
        await app.background()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(app.playback, "backgrounded while it waited: nothing starts")

        app.open(try link(browse.guide[1]))
        app.open(try link(browse.guide[2]))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(app.playback?.channel.id, browse.asChannel(browse.guide[2]).id, "the newer link wins")
        if let playback = app.playback { await app.endPlayback(playback) }

        app.open(try link(browse.guide[1]))
        app.beginPlayback(browse.asChannel(browse.guide[3])) // the user's own Watch
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(app.playback?.channel.id, browse.asChannel(browse.guide[3]).id, "the user's choice stands")
        if let playback = app.playback { await app.endPlayback(playback) }
    }

    /// #179: a second play before the player appears is watched too; the unseen replacement is ended.
    func testASwitchBeforeThePlayerAppearsIsStillWatched() async throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let app = AppModel()
        app.injectHomeFixture()
        let browse = try XCTUnwrap(app.browse)
        app.configureClientForTesting(try server.client(), browse: browse)
        let saved = UserDefaults.standard.data(forKey: LastWatched.key)
        defer { UserDefaults.standard.set(saved, forKey: LastWatched.key) }
        let deadline = AppModel.playerAppearDeadline
        AppModel.playerAppearDeadline = .milliseconds(300)
        defer { AppModel.playerAppearDeadline = deadline }
        app.beginPlayback(browse.asChannel(browse.guide[0]))
        try await Task.sleep(for: .milliseconds(100))
        app.switchPlayback(to: browse.asChannel(browse.guide[1]))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNil(app.playback, "the replacement never appeared either: ended")
        XCTAssertFalse(app.playbackBusy)
        XCTAssertFalse(app.playerPresented)
    }
}
