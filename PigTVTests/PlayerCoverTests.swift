import XCTest
import SwiftUI
@testable import PigTV

/// #301 (batch J review, lows): a recording's own full-screen cover rests the pages beneath it like the live player's,
/// and the Top Shelf is written as the app goes to the background.
@MainActor
final class PlayerCoverTests: XCTestCase {
    func testARecordingPlayerCoversThePagesUntilItCloses() {
        let app = AppModel()
        XCTAssertFalse(app.pagesCovered)
        app.recordingPlayer(presented: true)
        XCTAssertTrue(app.pagesCovered, "a playing recording rests the pages and the minute pass")
        XCTAssertFalse(app.playerPresented, "it is not the live player")
        app.recordingPlayer(presented: false)
        XCTAssertFalse(app.pagesCovered)
        app.recordingPlayer(presented: false)
        app.recordingPlayer(presented: true)
        XCTAssertTrue(app.pagesCovered, "a stray close never leaves a negative count")
    }

    /// Opus review of Apple 1 (medium): a session that ends with a recording's cover up (signed out, or the tree replaced)
    /// may never see its close; the next session's pages must not stay covered, so the count starts again with each one.
    func testANewSessionStartsWithThePagesUncovered() throws {
        let app = AppModel()
        app.recordingPlayer(presented: true)
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"4.0.0","apiVersion":1,"features":{}}"#.utf8))
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture", info: info))
        app.configureClientForTesting(browse.client, browse: browse)
        XCTAssertFalse(app.pagesCovered, "a new session's pages poll: the old cover's count is gone")
    }

    func testTheLivePlayerStillCoversThePages() {
        let app = AppModel()
        app.playerPresented = true
        XCTAssertTrue(app.pagesCovered)
    }

    /// The screen itself reports: presented on appear, not presented once it is gone.
    func testTheRecordingPlayerScreenReportsItsCover() async throws {
        final class Log: @unchecked Sendable { var events: [Bool] = [] }
        let log = Log()
        let client = APIClient(address: try ServerAddress("http://127.0.0.1:1"), token: "fixture")
        let recording = try JSONDecoder().decode(Recording.self, from: Data(#"{"id":30,"title":"The Headlines","status":"completed"}"#.utf8))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let root = RecordingPlayerScreen(recording: recording, client: client)
            .environment(\.pigRecordingPlayerCover, { log.events.append($0) })
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        for _ in 0..<100 where log.events.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(log.events, [true], "appearing marks the pages covered")
        window.rootViewController = nil
        window.isHidden = true
        for _ in 0..<100 where log.events.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(log.events, [true, false], "going away clears it")
    }

    func testTheTopShelfIsExportedOnceInTheBackgroundWithNoRequest() throws {
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"4.0.0","apiVersion":1,"features":{"library":true,"playbackResolve":true,"channelNumbers":true}}"#.utf8))
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:1"), token: "t", info: info))
        var exports = 0
        AppFreshness.exportOnBackground(browse, export: { _ in exports += 1 })
        XCTAssertEqual(exports, 1)
    }
}
