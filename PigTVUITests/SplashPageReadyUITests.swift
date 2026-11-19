import XCTest

/// #342 (Mark, 19 Nov 2026, TestFlight 324): the splash's pig lands on a page that is already still. The hand-off waits
/// until the opening page (Sport) has its first content, so when the splash goes the page is never its loading
/// placeholder. PIGTV_UI_TEST_LAUNCH=home is the real start-up path with a saved sign-in; PIGTV_UI_TEST_FRONT_DELAY makes the
/// Sport answer come 5 s after start-up (the splash would otherwise hand over at 3.2 s, on the placeholders: Apple 324).
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
        app.launchEnvironment["PIGTV_UI_TEST_FRONT_DELAY"] = "5"
        app.launch()
        let splash = app.otherElements["Starting PigTV"]
        XCTAssertTrue(splash.waitForExistence(timeout: 10), "the splash plays")
        // The page under the splash is hidden from accessibility until the splash has gone: then it is checked at once.
        XCTAssertTrue(waitUntil(20) { !splash.exists }, "the splash hands over (at the latest 4 s past the settled pig)")
        let loading = app.descendants(matching: .any)["sport.front.loading"]
        XCTAssertFalse(loading.exists, "the splash handed over to the Sport page's placeholders")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "landed-on-content"; shot.lifetime = .keepAlways
        add(shot)
    }
}
