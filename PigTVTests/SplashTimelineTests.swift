import XCTest
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

    func testTheHandoffLandsWhereTheHeaderSettlesAndHidesItsMarkUntilThen() {
        let handoff = SplashHandoff(playing: true, contentRise: 18)
        XCTAssertFalse(handoff.landed, "the header's mark is hidden while the splash's pig is the one on screen")
        XCTAssertFalse(handoff.contentShown)
        XCTAssertEqual(handoff.contentRise, 18)
        handoff.report(title: "Sport", frame: CGRect(x: 16, y: 88, width: 34, height: 28))
        handoff.report(title: "TV Guide", frame: CGRect(x: 16, y: 120, width: 34, height: 28))
        XCTAssertNil(handoff.target, "nothing to land on until the opening tab is known")
        handoff.landingTitle = "Sport"
        XCTAssertEqual(handoff.target, CGRect(x: 16, y: 70, width: 34, height: 28), "where the header will be once Home has risen")
        handoff.reveal()
        handoff.report(title: "Sport", frame: CGRect(x: 16, y: 80, width: 34, height: 28))
        XCTAssertEqual(handoff.target?.minY, 70, "frames reported while Home rises are not taken")
        XCTAssertTrue(handoff.contentShown)
        XCTAssertEqual(handoff.contentRise, 0)
        XCTAssertNil(handoff.restoreFinishedAt)
        handoff.restoreFinished()
        XCTAssertNotNil(handoff.restoreFinishedAt)
        handoff.land()
        XCTAssertTrue(handoff.landed)

        let none = SplashHandoff(playing: false, contentRise: 18)
        XCTAssertTrue(none.landed, "no splash (no saved sign-in): the header's mark shows")
        XCTAssertTrue(none.contentShown)
        XCTAssertEqual(none.contentRise, 0)
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
