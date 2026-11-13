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
}
