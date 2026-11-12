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

/// #46: the minute (and foreground) refresh brings a stale guide up to date; before build 79 only the TV Guide tab
/// did, so the Top Shelf showed yesterday after an overnight resume. #216 (Apple 102): Home, which ran it, is retired;
/// the app root runs it (`AppFreshness`, ContentView), whichever tab shows, and exports the Top Shelf each time.
@MainActor
final class AppFreshnessTests: XCTestCase {
    /// The fake server has no guide route, so every guide fetch is a 404 and would sit through the real retry backoff
    /// (8 s + 12 s) before the pass moved on. These tests count requests, not guides: fail at once.
    override func setUp() {
        super.setUp()
        BrowseModel.guidePageRetryDelaysOverride = []
    }

    override func tearDown() {
        BrowseModel.guidePageRetryDelaysOverride = nil
        super.tearDown()
    }

    func testTheRefreshAsksForAStaleGuideAndExportsTheTopShelf() async throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let browse = BrowseModel(client: try server.client())
        browse.guide = GuideFixtures.channels() // loaded, but never stamped: as old as it gets
        var exports = 0
        await AppFreshness.refresh(browse) { _ in exports += 1 }
        XCTAssertFalse(server.http.requests(path: "/api/library/guide", method: "GET").isEmpty,
                       "the stale guide is fetched again without any tab on screen")
        XCTAssertEqual(exports, 1, "the Top Shelf is exported after the refresh")
    }

    /// #239 (Apple 172): recordings are kept current by the same minute pass, and two askers inside the interval (a
    /// page and the pass, or two pages) make one request.
    func testTheRefreshLoadsStaleRecordingsOnceForEveryAsker() async throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let browse = BrowseModel(client: try server.client())
        browse.guide = GuideFixtures.channels()
        await AppFreshness.refresh(browse) { _ in }
        XCTAssertEqual(server.http.requests(path: "/api/recordings", method: "GET").count, 1, "the pass loads stale recordings")
        await browse.loadRecordingsIfStale(maxAge: AppFreshness.recordingsMaxAge, quietly: true) // a page asking too
        await AppFreshness.refresh(browse) { _ in }
        XCTAssertEqual(server.http.requests(path: "/api/recordings", method: "GET").count, 1, "one request for every asker")
    }

    func testTheRefreshDoesNothingOnTheOfflineFixture() async throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let browse = BrowseModel(client: try server.client())
        browse.isFixture = true
        var exports = 0
        await AppFreshness.refresh(browse) { _ in exports += 1 }
        XCTAssertEqual(exports, 0)
        XCTAssertTrue(server.http.requests(path: "/api/library/guide", method: "GET").isEmpty)
    }

    /// The loop on an injected clock: a pass at once, then one per minute, and none after the task ends.
    func testTheLoopRefreshesAtOnceThenEveryMinuteUntilCancelled() async {
        var slept: [Duration] = []
        var passes = 0
        struct Stop: Error {}
        await AppFreshness.run(sleep: { duration in
            slept.append(duration)
            if slept.count == 3 { throw Stop() } // the task is cancelled during the third minute
        }) { passes += 1 }
        XCTAssertEqual(passes, 3, "at once, after the first minute and after the second")
        XCTAssertEqual(slept, [.seconds(60), .seconds(60), .seconds(60)])
    }

    /// #278 (audit F1): under the full-screen player nobody sees the pages, so a pass sends nothing and exports nothing.
    func testAPassWhilePlayingSendsNothingAndExportsNothing() async throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let browse = BrowseModel(client: try server.client())
        browse.guide = GuideFixtures.channels() // stale: a pass that ran would ask for it
        var exports = 0
        await AppFreshness.refresh(browse, playing: true) { _ in exports += 1 }
        XCTAssertEqual(server.http.requests.count, 0, "no request of any kind while the player is up")
        XCTAssertEqual(exports, 0, "no Top Shelf export while the player is up")
    }

    func testAPassWithoutThePlayerStillAsksAndExports() async throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let browse = BrowseModel(client: try server.client())
        browse.guide = GuideFixtures.channels()
        var exports = 0
        await AppFreshness.refresh(browse, playing: false) { _ in exports += 1 }
        XCTAssertFalse(server.http.requests(path: "/api/library/guide", method: "GET").isEmpty)
        XCTAssertFalse(server.http.requests(path: "/api/recordings", method: "GET").isEmpty)
        XCTAssertEqual(exports, 1)
    }

    /// The loop: nothing while playing (it only looks again every second), a pass as soon as the player closes, then the
    /// minute clock as before. Opening the player mid-wait makes no pass either.
    func testTheLoopRestsWhilePlayingAndRefreshesAtOnceWhenThePlayerCloses() async {
        var playing = true
        var slept: [Duration] = []
        var passes = 0
        struct Stop: Error {}
        await AppFreshness.run(playing: { playing }, sleep: { duration in
            slept.append(duration)
            if slept.count == 3 { playing = false } // the player closes during the third second
            if slept.count == 4 { throw Stop() }
        }) { passes += 1 }
        XCTAssertEqual(slept, [.seconds(1), .seconds(1), .seconds(1), .seconds(60)])
        XCTAssertEqual(passes, 1, "none while the player was up, one the moment it closed, none yet for the next minute")
    }

    func testThePlayerOpeningDuringTheMinuteMakesNoPassWhenItWakes() async {
        var playing = false
        var slept: [Duration] = []
        var passes = 0
        struct Stop: Error {}
        await AppFreshness.run(playing: { playing }, sleep: { duration in
            slept.append(duration)
            if slept.count == 1 { playing = true }
            if slept.count == 3 { throw Stop() }
        }) { passes += 1 }
        XCTAssertEqual(slept, [.seconds(60), .seconds(1), .seconds(1)])
        XCTAssertEqual(passes, 1, "only the first pass, before the player opened")
    }

    /// #278 (F1): favourites are asked at most every 5 minutes by the minute pass: loaded 2 minutes ago, a pass asks
    /// nothing (the old 60 s age asked again); loaded 6 minutes ago, it asks once.
    func testTheMinutePassAsksForFavouritesOnlyEveryFiveMinutes() async throws {
        XCTAssertGreaterThan(AppFreshness.favouritesMaxAge, BrowseModel.appearMaxAge)
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let browse = BrowseModel(client: try server.client())
        browse.guide = GuideFixtures.channels()
        let asked = { server.http.requests(path: "/api/library/favourites", method: "GET").count }
        await AppFreshness.refresh(browse) { _ in }
        XCTAssertEqual(asked(), 1, "control: a first pass asks")
        browse.setFavouritesLoaded(at: Date().addingTimeInterval(-120))
        await AppFreshness.refresh(browse) { _ in }
        XCTAssertEqual(asked(), 1, "loaded 2 minutes ago: the minute pass asks nothing")
        browse.setFavouritesLoaded(at: Date().addingTimeInterval(-360))
        await AppFreshness.refresh(browse) { _ in }
        XCTAssertEqual(asked(), 2, "loaded 6 minutes ago: it asks once")
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
