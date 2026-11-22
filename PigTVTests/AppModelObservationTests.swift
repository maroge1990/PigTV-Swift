import SwiftUI
import XCTest
@testable import PigTV

/// maroge1990/PigTV#50: AppModel is @Observable, so a root view is re-evaluated only by the AppModel properties its body
/// reads. As an ObservableObject, any change re-evaluated every view holding it: a channel change in the player
/// (`switchPlayback`) re-evaluated the tab bar (LibraryView) and the whole TV Guide page beneath the player, and so did
/// a player notice or any other unrelated property. Each count below was one or more on 392.
@MainActor
final class AppModelObservationTests: XCTestCase {
    private var window: UIWindow?
    private var deadline: Duration?

    override func setUp() async throws {
        deadline = AppModel.playerAppearDeadline
        AppModel.playerAppearDeadline = nil // no player screen here: the unseen play must not be ended meanwhile
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        AppModel.playerAppearDeadline = deadline
    }

    /// The tab bar on the TV Guide over a play (the player fixture's: a zap list, a channel playing, nothing resolving),
    /// in a window, settled.
    private func hostPlaying() async throws -> AppModel {
        #if os(iOS)
        // As GuideQuietTests: the upright iPhone's Guide is the On now list; the iPad runs this.
        if UIDevice.current.userInterfaceIdiom == .phone { throw XCTSkip("the iPhone's Guide has no grid") }
        #endif
        let app = AppModel()
        app.injectPlayerFixture(media: nil)
        XCTAssertNotNil(app.playback)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: LibraryView(model: app, initialTab: "guide"))
        window.makeKeyAndVisible()
        self.window = window
        let end = Date().addingTimeInterval(10)
        while GuidePerf.bodyEvaluationsForTesting == 0 && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(GuidePerf.bodyEvaluationsForTesting, 0, "the Guide is on screen")
        try await settle()
        return app
    }

    /// Until neither body has been evaluated for a whole second (up to 10 s): the first screen's own steps are done.
    private func settle() async throws {
        var last = counts()
        var quietSince = Date()
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            try await Task.sleep(for: .milliseconds(100))
            let now = counts()
            if now != last { last = now; quietSince = Date() } else if Date().timeIntervalSince(quietSince) >= 1 { return }
        }
    }

    private func counts() -> [Int] { [GuidePerf.bodyEvaluationsForTesting, LibraryView.bodyEvaluationsForTesting] }

    /// Body evaluations of GuideView and LibraryView while `event` runs, and for a second after it.
    private func evaluations(during event: () -> Void) async throws -> (guide: Int, library: Int) {
        let before = counts()
        event()
        try await Task.sleep(for: .seconds(1))
        let after = counts()
        return (after[0] - before[0], after[1] - before[1])
    }

    /// A channel change in the player: a new `playback` and `previousChannel`, nothing either page reads.
    private func zap(_ app: AppModel) throws {
        let playing = try XCTUnwrap(app.playback)
        let next = try XCTUnwrap(app.zapList.first { $0.id != playing.channel.id })
        app.switchPlayback(to: next)
        XCTAssertFalse(app.playback === playing, "the channel changed")
    }

    func testAChannelChangeDoesNotReevaluateTheGuide() async throws {
        let app = try await hostPlaying()
        let seen = try await evaluations { try? zap(app) }
        XCTAssertEqual(seen.guide, 0, "a channel change re-evaluated GuideView.body")
    }

    func testAChannelChangeDoesNotReevaluateTheTabBar() async throws {
        let app = try await hostPlaying()
        let seen = try await evaluations { try? zap(app) }
        XCTAssertEqual(seen.library, 0, "a channel change re-evaluated LibraryView.body")
    }

    /// The player's notice and Sign in's server step: AppModel properties neither page reads.
    func testAnUnrelatedChangeDoesNotReevaluateTheGuide() async throws {
        let app = try await hostPlaying()
        let seen = try await evaluations {
            app.playerNotice = "That game is no longer on"
            app.signInAtServer.toggle()
        }
        XCTAssertEqual(seen.guide, 0, "an unrelated AppModel change re-evaluated GuideView.body")
        XCTAssertEqual(seen.library, 0, "an unrelated AppModel change re-evaluated LibraryView.body")
    }

    /// What the pages do read still redraws them: the categories (the Guide's chips) and a requested tab (the tab bar).
    func testWhatThePagesReadStillReevaluatesThem() async throws {
        let app = try await hostPlaying()
        let guide = try await evaluations { app.requestedTab = "guide" }
        XCTAssertGreaterThan(guide.library, 0, "a requested tab re-evaluates LibraryView")
        let ended = try await evaluations { app.playback = nil }
        XCTAssertGreaterThan(ended.guide, 0, "the end of the play re-evaluates GuideView (it refocuses the grid)")
    }
}
