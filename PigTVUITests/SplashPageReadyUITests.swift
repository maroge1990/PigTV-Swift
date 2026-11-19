import XCTest

/// #342 (Mark, 19 Nov 2026, TestFlight 324): the splash's pig lands on a page that is already still. The hand-off waits
/// until the opening page (Sport) has its first content, so when the splash goes the page is never its loading
/// placeholder. PIGTV_UI_TEST_LAUNCH=home is the real start-up path with a saved sign-in; PIGTV_UI_TEST_FRONT_DELAY makes the
/// Sport answer come 3 s after start-up, about 3.6 s into the splash (it would otherwise hand over from 2.0 s and be gone at
/// 3.2 s, on the placeholders: Apple 324; the cap, 6 s, leaves room on a slow simulator).
final class SplashPageReadyUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    override func tearDown() {
        // Removes the fixture's saved sign-in (LaunchFixture.clear).
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_LAUNCH"] = "clear"
        app.launch()
        app.terminate()
    }

    @MainActor func testTheSplashHandsOverOnlyOnceTheOpeningPageHasItsContent() {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_LAUNCH"] = "home"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launchEnvironment["PIGTV_UI_TEST_FRONT_DELAY"] = "3"
        app.launch()
        let splash = app.otherElements["Starting PigTV"]
        XCTAssertTrue(splash.waitForExistence(timeout: 10), "the splash plays")
        let shown = Date()
        // The page under the splash is hidden from accessibility until the splash has gone: then it is checked at once.
        XCTAssertTrue(waitUntil(20) { !splash.exists }, "the splash hands over (at the latest 4 s past the settled pig)")
        // The answer is in at about 3.6 s, so the hand-off ends near 5 s; waiting out the cap would end at 7.2 s.
        XCTAssertLessThan(Date().timeIntervalSince(shown), 6.5, "the splash went when the page was ready, not at the cap")
        let loading = app.descendants(matching: .any)["sport.front.loading"]
        XCTAssertFalse(loading.exists, "the splash handed over to the Sport page's placeholders")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "landed-on-content"; shot.lifetime = .keepAlways
        add(shot)
    }
}
