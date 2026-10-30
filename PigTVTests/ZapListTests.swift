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
}
