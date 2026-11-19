import XCTest
import SwiftUI
@testable import PigTV

// maroge1990/PigTV#342 (option C, "Into the header"): the splash plays its whole sequence (about 3.2 s) even when
// start-up is quicker, waits on the settled pig and name when it is slower, then flies the pig onto Home's header mark.
// Before this change the splash went the moment the restore finished (no SplashTimeline, SplashFlight or SplashHandoff:
// these tests fail to compile on Apple 291).
@MainActor
final class SplashTimelineTests: XCTestCase {
    func testTheSequenceIsTheMocksTimings() {
        XCTAssertEqual(SplashTimeline.launchHold, 0.6)
        XCTAssertEqual(SplashTimeline.launchHold + SplashTimeline.nameDelay, 0.95, accuracy: 1e-9, "the name starts 0.35 s after the bloom")
        XCTAssertEqual(SplashTimeline.bloomSwell + SplashTimeline.bloomSettle, 1.5, accuracy: 1e-9)
        XCTAssertEqual(SplashTimeline.settled, 2.0)
        XCTAssertEqual(SplashTimeline.minimumLength, 3.2, accuracy: 1e-9)
        XCTAssertEqual(SplashTimeline.flightDelay + SplashTimeline.flight, SplashTimeline.revealDelay + SplashTimeline.reveal,
                       accuracy: 1e-9, "the pig lands as Home settles, so the header's mark takes over with nothing moving")
    }

    func testAQuickStartUpStillGetsTheWholeSplash() {
        // The restore finished at 0.2 s: the hand-off still waits for the settled pig and name.
        XCTAssertEqual(SplashTimeline.handoffStart(restoreFinishedAt: 0.2), 2.0)
        XCTAssertEqual(SplashTimeline.end(restoreFinishedAt: 0.2) ?? 0, 3.2, accuracy: 1e-9)
        XCTAssertEqual(SplashTimeline.phase(at: 0.3, restoreFinishedAt: 0.2), .launchFrame)
        XCTAssertEqual(SplashTimeline.phase(at: 1.0, restoreFinishedAt: 0.2), .namingIn)
        XCTAssertEqual(SplashTimeline.phase(at: 1.8, restoreFinishedAt: 0.2), .settled)
        XCTAssertEqual(SplashTimeline.phase(at: 2.5, restoreFinishedAt: 0.2), .handingOff)
        XCTAssertEqual(SplashTimeline.phase(at: 3.2, restoreFinishedAt: 0.2), .done)
    }

    func testASlowStartUpWaitsOnTheSettledPigAndName() {
        XCTAssertNil(SplashTimeline.handoffStart(restoreFinishedAt: nil))
        XCTAssertEqual(SplashTimeline.phase(at: 10, restoreFinishedAt: nil), .settled, "never leaves while start-up runs")
        XCTAssertEqual(SplashTimeline.handoffStart(restoreFinishedAt: 5), 5)
        XCTAssertEqual(SplashTimeline.end(restoreFinishedAt: 5) ?? 0, 6.2, accuracy: 1e-9)
        XCTAssertEqual(SplashTimeline.phase(at: 5.5, restoreFinishedAt: 5), .handingOff)
    }

    /// Mark, 19 Nov 2026: Home's 18 pt glide is back, drawn as a UIKit transform on the tabs' view, which SwiftUI's layout
    /// and frames never see; so the landing spot is the header's frame as reported, whatever the rise (before Apple 325
    /// it was the frame less the rise, measured on a page that the offset had laid out again). Fails to compile on the
    /// previous commit (no contentRise or glide).
    func testTheGlideIsATransformAndTheLandingSpotIgnoresTheRise() {
        let handoff = SplashHandoff(playing: true, contentRise: 32.4)
        handoff.landingTitle = "Sport"
        handoff.report(title: "Sport", frame: CGRect(x: 80, y: 157, width: 58, height: 48))
        XCTAssertEqual(handoff.target, CGRect(x: 80, y: 157, width: 58, height: 48), "the settled frame, not less the rise")
        let tabs = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        handoff.glide(tabs, rise: handoff.contentRise)
        XCTAssertEqual(tabs.transform, CGAffineTransform(translationX: 0, y: 32.4), "drawn low under the splash")
        XCTAssertEqual(tabs.frame.size, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(tabs.bounds, CGRect(x: 0, y: 0, width: 1920, height: 1080), "its layout is untouched")
        handoff.land()
        XCTAssertEqual(tabs.transform, .identity, "in place once the splash has gone")
        let other = UIView()
        handoff.glide(other, rise: 32.4)
        XCTAssertEqual(other.transform, .identity, "nothing glides after the splash")
        let reduced = SplashHandoff(playing: true, contentRise: 32.4)
        let still = UIView()
        reduced.glide(still, rise: 0)
        XCTAssertEqual(still.transform, .identity, "Reduce Motion: no glide, a fade only")
    }

    /// Codex sign-off of 325 (medium): the tabs' view is drawn low from when the probe finds it until the reveal. A splash
    /// cancelled in that wait (the view went away) returned before land(), and a probe that left, or a tab controller
    /// replaced, left the view drawn low (a second view was ignored while the first lived). Every way out now puts it
    /// back. (No waitForHandoff, resetGlide or glideViewLost: fails to compile on c843b37.)
    func testTheTabsAreNeverLeftDrawnLow() async {
        let handoff = SplashHandoff(playing: true, contentRise: 18)
        let tabs = UIView()
        handoff.glide(tabs, rise: 18)
        XCTAssertEqual(tabs.transform.ty, 18)
        let wait = Task { try await handoff.waitForHandoff(poll: .milliseconds(10)) } // start-up never finishes
        try? await Task.sleep(for: .milliseconds(60))
        wait.cancel()
        _ = await wait.result
        XCTAssertEqual(tabs.transform, .identity, "cancelled while waiting: the retained view is back in place")

        let replaced = SplashHandoff(playing: true, contentRise: 18)
        let first = UIView(), second = UIView()
        replaced.glide(first, rise: 18)
        replaced.glide(first, rise: 18)
        XCTAssertEqual(first.transform.ty, 18, "found again: unchanged")
        replaced.glide(second, rise: 18)
        XCTAssertEqual(first.transform, .identity, "the tab controller replaced: the old view is put back")
        XCTAssertEqual(second.transform.ty, 18, "and the new one glides")
        replaced.glideViewLost(first)
        XCTAssertEqual(second.transform.ty, 18, "a view no longer gliding changes nothing")
        replaced.glideViewLost(second)
        XCTAssertEqual(second.transform, .identity, "its probe left the window: put back")
        replaced.resetGlide()
        replaced.land()
        XCTAssertEqual(second.transform, .identity, "idempotent")
    }

    /// Mark, 19 Nov 2026 (TestFlight 324): the pig lands on a page that is already still. The hand-off waits for the opening
    /// page's first content (and `pageSettle` for its layout), but never more than 4 s past the settled pig and name (or
    /// start-up's end). Before Apple 325 it went at max(2.0, start-up) whatever the page showed (no pageReadyAt: these
    /// fail to compile on 324).
    func testTheHandoffWaitsForTheOpeningPagesFirstContentCapped() {
        XCTAssertEqual(SplashTimeline.pageWaitCap, 4)
        XCTAssertEqual(SplashTimeline.handoffStart(restoreFinishedAt: 0.2, pageReadyAt: 0.6), 2.0, "in before the pig settles: no wait")
        XCTAssertEqual(SplashTimeline.handoffStart(restoreFinishedAt: 0.2, pageReadyAt: 3.0) ?? 0, 3.0 + SplashTimeline.pageSettle,
                       accuracy: 1e-9, "the page's content came at 3.0 s: it is laid out, then the pig flies")
        XCTAssertEqual(SplashTimeline.handoffStart(restoreFinishedAt: 0.2, pageReadyAt: nil), 6.0, "not in yet: the cap, 4 s past the settled pig")
        XCTAssertEqual(SplashTimeline.handoffStart(restoreFinishedAt: 0.2, pageReadyAt: 9.0), 6.0, "too late: handed over at the cap")
        XCTAssertEqual(SplashTimeline.handoffStart(restoreFinishedAt: 5.0, pageReadyAt: nil), 9.0, "the cap counts from start-up's end when later")
        XCTAssertNil(SplashTimeline.handoffStart(restoreFinishedAt: nil, pageReadyAt: 1.0), "start-up first")
        XCTAssertEqual(SplashTimeline.phase(at: 4.0, restoreFinishedAt: 0.2, pageReadyAt: nil), .settled, "still waiting on the page")
        XCTAssertEqual(SplashTimeline.phase(at: 6.5, restoreFinishedAt: 0.2, pageReadyAt: nil), .handingOff)
        XCTAssertEqual(SplashTimeline.end(restoreFinishedAt: 0.2, pageReadyAt: 3.0) ?? 0, 3.15 + 1.2, accuracy: 1e-9)
    }

    func testTheHandoffKnowsWhenTheOpeningPageIsReady() {
        let handoff = SplashHandoff(playing: true)
        XCTAssertEqual(handoff.pageReadyAt, 0, "no header to land on (sign-in, Offline): nothing to wait for")
        handoff.landingTitle = "Sport"
        XCTAssertNil(handoff.pageReadyAt, "Sport has not said its content is in")
        handoff.pageReady(title: "TV Guide")
        XCTAssertNil(handoff.pageReadyAt, "another page's content does not count")
        handoff.pageReady(title: "Sport")
        let first = try? XCTUnwrap(handoff.pageReadyAt)
        XCTAssertNotNil(first)
        handoff.pageReady(title: "Sport")
        XCTAssertEqual(handoff.pageReadyAt, first, "the first time counts")
        XCTAssertNil(handoff.handoffStart, "start-up still runs")
        handoff.restoreFinished()
        XCTAssertEqual(handoff.handoffStart, 2.0, "both in quickly: the hand-off at the settled pig")
    }

    func testTheProgressIndicatorOnlyWhenStartUpOutlastsTheSequence() {
        XCTAssertFalse(SplashTimeline.showsProgress(at: 2.5, restoreFinished: false), "not while the sequence still plays")
        XCTAssertTrue(SplashTimeline.showsProgress(at: 3.2, restoreFinished: false))
        XCTAssertFalse(SplashTimeline.showsProgress(at: 4, restoreFinished: true))
    }

    func testTheFlightNeedsMotionAndAHeaderPig() {
        XCTAssertEqual(SplashTimeline.handoff(reduceMotion: false, hasTarget: true), .flight)
        XCTAssertEqual(SplashTimeline.handoff(reduceMotion: true, hasTarget: true), .crossFade, "Reduce Motion: a plain cross-fade")
        XCTAssertEqual(SplashTimeline.handoff(reduceMotion: false, hasTarget: false), .crossFade, "sign-in or Offline: no header")
    }

    func testThePigLandsOnTheHeaderMarkAtItsSize() {
        // iPhone: the header's 34 x 28 mark at (16, 70); the splash pig is 0.42 x 600 = 252 pt wide, centred on screen.
        let splash = CGRect(x: 0, y: 0, width: 402, height: 874)
        let landing = SplashFlight.landing(mark: CGRect(x: 16, y: 70, width: 34, height: 28), splash: splash, pigInkWidth: 252)
        XCTAssertEqual(landing.scale, 34.0 / 252, accuracy: 1e-9)
        XCTAssertEqual(landing.offset.width, 33 - 201, accuracy: 1e-9)
        XCTAssertEqual(landing.offset.height, 84 - 437, accuracy: 1e-9)
        // A frame taller than the ink's footprint: the ink is as wide as the height allows (PigBrandMark).
        XCTAssertEqual(SplashFlight.landing(mark: CGRect(x: 0, y: 0, width: 100, height: 40), splash: splash, pigInkWidth: 200).scale,
                       40.0 * 1000 / 797 / 200, accuracy: 1e-9)
    }

    func testTheHandoffLandsWhereTheHeaderIsAndHidesItsMarkUntilThen() {
        let handoff = SplashHandoff(playing: true)
        XCTAssertFalse(handoff.landed, "the header's mark is hidden while the splash's pig is the one on screen")
        XCTAssertFalse(handoff.contentShown)
        handoff.report(title: "Sport", frame: CGRect(x: 16, y: 70, width: 34, height: 28))
        handoff.report(title: "TV Guide", frame: CGRect(x: 16, y: 120, width: 34, height: 28))
        XCTAssertNil(handoff.target, "nothing to land on until the opening tab is known")
        handoff.landingTitle = "Sport"
        XCTAssertEqual(handoff.target, CGRect(x: 16, y: 70, width: 34, height: 28), "where the header is, and stays")
        handoff.reveal()
        handoff.report(title: "Sport", frame: CGRect(x: 16, y: 80, width: 34, height: 28))
        XCTAssertEqual(handoff.target?.minY, 70, "frames reported while Home fades in are not taken")
        XCTAssertTrue(handoff.contentShown)
        XCTAssertFalse(handoff.homeInteractive, "Home fades in under the splash but takes no input or focus yet (#342 review)")
        XCTAssertNil(handoff.restoreFinishedAt)
        handoff.restoreFinished()
        XCTAssertNotNil(handoff.restoreFinishedAt)
        handoff.land()
        XCTAssertTrue(handoff.landed)
        XCTAssertTrue(handoff.homeInteractive, "the splash gone: Home takes input and focus")

        let none = SplashHandoff(playing: false)
        XCTAssertTrue(none.landed, "no splash (no saved sign-in): the header's mark shows")
        XCTAssertTrue(none.contentShown)
        XCTAssertTrue(none.homeInteractive)
    }

    /// #342, iPhone (TestFlight 324): the pig did not fly onto the Sport header. The splash's bloom (1088 pt across on an
    /// iPhone, 1960 on the Apple TV) made the splash wider than the screen, and ContentView's ZStack took its size, so Home
    /// was laid out 1088 pt wide under the splash: the iPhone's header mark sat at x -327 and the pig flew off to the top
    /// left (the iPad's, 28 pt off, snapped across when the splash went). The splash now takes exactly the screen it is
    /// given. Fails on Apple 324 (1088.6 pt wide).
    func testTheSplashNeverOutgrowsTheScreen() {
        #if os(tvOS)
        let screen = CGSize(width: 1920, height: 1080)
        #else
        let screen = CGSize(width: 402, height: 874)
        #endif
        let size = UIHostingController(rootView: BrandSplashView()).sizeThatFits(in: screen)
        XCTAssertLessThanOrEqual(size.width, screen.width, "the splash is no wider than the screen")
        XCTAssertLessThanOrEqual(size.height, screen.height, "the splash is no taller than the screen")
    }

    func testTheNameSitsWhereTheStackedLockupHasIt() {
        // lockup-stacked-*.svg: pig ink 257.45 wide centred at (236.495, 170.59); the wordmark (363 x 129 at 0.55615) at
        // (135.73, 309.12): centred under the pig.
        XCTAssertEqual(BrandLayout.stackedWordmarkSize.width, 363 * 0.55615 / 257.45, accuracy: 1e-9)
        XCTAssertEqual(BrandLayout.stackedWordmarkCentreFromPig.x, 0, accuracy: 0.002)
        XCTAssertEqual(BrandLayout.stackedWordmarkCentreFromPig.y, (309.12 + 129 * 0.55615 / 2 - 170.59) / 257.45, accuracy: 1e-6)
        XCTAssertGreaterThan(BrandLayout.stackedWordmarkCentreFromPig.y - BrandLayout.stackedWordmarkSize.height / 2,
                             BrandLayout.markInkAspect / 2, "the name is below the pig's ink")
    }
}
