import XCTest
import SwiftUI
@testable import PigTV

// Every open starts from scratch (Mark, 18 Nov 2026): a return from the background goes back to the opening tab at its
// root and replays the splash onto its header pig, as a cold launch does. Before this change a return kept whatever page
// was open and never splashed (no ForegroundReset or SplashHandoff.replay: these tests fail to compile on Apple 319).
@MainActor
final class ForegroundResetTests: XCTestCase {
    private let play = URL(string: "pigtv://play?id=7&name=BBC%20One")!

    /// The phases iOS and tvOS send for a trip to the background and back.
    private func goAwayAndBack(_ reset: inout ForegroundReset, playerUp: Bool = false,
                               signedIn: Bool = true) -> ForegroundReset.Step {
        _ = reset.sceneChanged(to: .inactive, playerUp: playerUp, signedIn: signedIn)
        _ = reset.sceneChanged(to: .background, playerUp: playerUp, signedIn: signedIn)
        _ = reset.sceneChanged(to: .inactive, playerUp: playerUp, signedIn: signedIn)
        return reset.sceneChanged(to: .active, playerUp: playerUp, signedIn: signedIn)
    }

    func testAReturnFromTheBackgroundResetsAndSplashes() {
        var reset = ForegroundReset()
        XCTAssertEqual(goAwayAndBack(&reset), ForegroundReset.Step(reset: true))
        XCTAssertTrue(reset.splashing)
        XCTAssertEqual(goAwayAndBack(&reset), ForegroundReset.Step(reset: true), "every return, not only the first")
    }

    func testAnInactiveBlipChangesNothing() {
        var reset = ForegroundReset()
        // Control Center, a system alert: active → inactive → active, never the background.
        XCTAssertEqual(reset.sceneChanged(to: .inactive, playerUp: false, signedIn: true), ForegroundReset.Step())
        XCTAssertEqual(reset.sceneChanged(to: .active, playerUp: false, signedIn: true), ForegroundReset.Step())
        XCTAssertFalse(reset.splashing)
        XCTAssertTrue(reset.linkArrived(play), "a link with no return from the background opens at once")
    }

    func testAPlayerThatIsUpIsKeptAndNothingSplashes() {
        var reset = ForegroundReset()
        // Watching, Picture in Picture or background audio: the player stays presented through the background.
        XCTAssertEqual(goAwayAndBack(&reset, playerUp: true), ForegroundReset.Step())
        XCTAssertFalse(reset.splashing)
    }

    func testNoSessionNoSplash() {
        var reset = ForegroundReset()
        XCTAssertEqual(goAwayAndBack(&reset, signedIn: false), ForegroundReset.Step(), "sign-in and Offline have no header")
    }

    func testALinkWithTheReturnPlaysAfterTheSplash() {
        var reset = ForegroundReset()
        _ = reset.sceneChanged(to: .background, playerUp: false, signedIn: true)
        // The Top Shelf's link arrives as the scene comes back, before it is active.
        _ = reset.sceneChanged(to: .inactive, playerUp: false, signedIn: true)
        XCTAssertFalse(reset.linkArrived(play), "held: the pages are about to be reset")
        XCTAssertEqual(reset.sceneChanged(to: .active, playerUp: false, signedIn: true), ForegroundReset.Step(reset: true))
        let game = URL(string: "pigtv://game?id=nrl-1")!
        XCTAssertFalse(reset.linkArrived(game), "still held while the splash plays")
        XCTAssertEqual(reset.splashLanded(), [play, game], "opened in order once the splash has landed")
        XCTAssertTrue(reset.linkArrived(play), "afterwards links open at once")
        XCTAssertEqual(reset.splashLanded(), [])
    }

    /// Codex review of 320: the scene went back to the background while the splash played, with a link queued; the
    /// splash's landing then (its timer ran on) opens nothing: the link waits for the next return's splash.
    func testALinkQueuedWhenTheSceneLeavesAgainDuringTheSplashWaitsForTheNextReturn() {
        var reset = ForegroundReset()
        _ = reset.sceneChanged(to: .background, playerUp: false, signedIn: true)
        XCTAssertFalse(reset.linkArrived(play))
        XCTAssertEqual(reset.sceneChanged(to: .active, playerUp: false, signedIn: true), ForegroundReset.Step(reset: true))
        _ = reset.sceneChanged(to: .inactive, playerUp: false, signedIn: true)
        _ = reset.sceneChanged(to: .background, playerUp: false, signedIn: true)
        XCTAssertEqual(reset.splashLanded(), [], "landed in the background: nothing opens")
        XCTAssertEqual(reset.heldLinks, [play], "still queued")
        XCTAssertEqual(goAwayAndBackFromBackground(&reset), ForegroundReset.Step(reset: true), "the next return splashes again")
        XCTAssertEqual(reset.splashLanded(), [play], "and opens the link once that splash has landed")
    }

    /// Codex sign-off of 320: the splash lands during an .inactive interruption (Control Center, no background): the
    /// held link opens when the scene is active again.
    func testALinkHeldWhenTheSplashLandsDuringAnInactiveBlipOpensOnActivation() {
        var reset = ForegroundReset()
        _ = reset.sceneChanged(to: .background, playerUp: false, signedIn: true)
        XCTAssertFalse(reset.linkArrived(play))
        XCTAssertEqual(reset.sceneChanged(to: .active, playerUp: false, signedIn: true), ForegroundReset.Step(reset: true))
        _ = reset.sceneChanged(to: .inactive, playerUp: false, signedIn: true)
        XCTAssertEqual(reset.splashLanded(), [], "not active: kept")
        XCTAssertEqual(reset.sceneChanged(to: .active, playerUp: false, signedIn: true), ForegroundReset.Step(open: [play]),
                       "active again with the splash landed: it opens")
        XCTAssertEqual(reset.heldLinks, [])
        // A blip while a splash still plays opens nothing yet.
        _ = reset.sceneChanged(to: .background, playerUp: false, signedIn: true)
        XCTAssertFalse(reset.linkArrived(play))
        _ = reset.sceneChanged(to: .active, playerUp: false, signedIn: true)
        _ = reset.sceneChanged(to: .inactive, playerUp: false, signedIn: true)
        XCTAssertEqual(reset.sceneChanged(to: .active, playerUp: false, signedIn: true), ForegroundReset.Step())
        XCTAssertEqual(reset.splashLanded(), [play])
    }

    private func goAwayAndBackFromBackground(_ reset: inout ForegroundReset) -> ForegroundReset.Step {
        _ = reset.sceneChanged(to: .inactive, playerUp: false, signedIn: true)
        return reset.sceneChanged(to: .active, playerUp: false, signedIn: true)
    }

    func testALinkWithTheReturnToAPlayerOpensAtOnce() {
        var reset = ForegroundReset()
        _ = reset.sceneChanged(to: .background, playerUp: true, signedIn: true)
        XCTAssertFalse(reset.linkArrived(play))
        XCTAssertEqual(reset.sceneChanged(to: .active, playerUp: true, signedIn: true), ForegroundReset.Step(open: [play]),
                       "no splash, so the held link opens as the scene is active (it switches the player's channel)")
    }

    func testTheReplayedSplashLandsOnTheOpeningTabsHeader() {
        let sport = SplashHandoff.replay(landingOn: LibraryView.openingTab(sportEnabled: true), contentRise: 18)
        XCTAssertFalse(sport.landed, "the splash plays")
        XCTAssertFalse(sport.homeInteractive)
        XCTAssertFalse(sport.contentShown, "the pages are under the splash until it hands over")
        XCTAssertEqual(sport.landingTitle, "Sport")
        XCTAssertNotNil(sport.restoreFinishedAt, "nothing to restore: the hand-off follows the settled pig and name")
        sport.report(title: "Sport", frame: CGRect(x: 60, y: 118, width: 50, height: 40))
        XCTAssertEqual(sport.target, CGRect(x: 60, y: 100, width: 50, height: 40), "where the header settles")
        let guide = SplashHandoff.replay(landingOn: LibraryView.openingTab(sportEnabled: false), contentRise: 0)
        XCTAssertEqual(guide.landingTitle, "TV Guide")
    }
}
