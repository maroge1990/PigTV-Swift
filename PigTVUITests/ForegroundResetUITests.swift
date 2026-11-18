import XCTest

/// Every open starts from scratch (Mark, 18 Nov 2026): leaving PigTV on another tab and coming back from the background
/// plays the splash again, and its pig lands on the opening tab's header (Sport, on the launch fixture), as a cold launch
/// does. PIGTV_UI_TEST_LAUNCH=home: the real start-up path (ContentView) with a saved sign-in that lands on the fixture.
final class ForegroundResetUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    override func tearDown() {
        // Removes the fixture's saved sign-in (LaunchFixture.clear).
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_LAUNCH"] = "clear"
        app.launch()
        app.terminate()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func headerTitle(_ app: XCUIApplication) -> String? {
        let title = app.descendants(matching: .any).matching(identifier: "page.header.title")
            .allElementsBoundByIndex.first { $0.isHittable }
        return title?.label
    }

    #if os(tvOS)
    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }
    #endif

    /// Leaves the opening tab for Settings.
    private func openSettings(_ app: XCUIApplication) {
        #if os(tvOS)
        let bar = app.tabBars.firstMatch
        for _ in 0..<10 {
            let frame = focused(app).frame
            if focused(app).exists, frame.maxY <= bar.frame.maxY + 1, frame.height > 0 { break }
            XCUIRemote.shared.press(.up)
        }
        for _ in 0..<3 { XCUIRemote.shared.press(.right) }
        #else
        app.tabBars.buttons["Settings"].tap()
        #endif
    }

    /// Another app comes to the front (the system's Settings), which sends PigTV to the background, then PigTV again.
    private func goToTheBackgroundAndBack(_ app: XCUIApplication) {
        #if os(tvOS)
        let other = XCUIApplication(bundleIdentifier: "com.apple.TVSettings")
        #else
        let other = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        #endif
        other.activate()
        XCTAssertTrue(waitUntil(15) { app.state == .runningBackground || app.state == .runningBackgroundSuspended },
                      "the app went to the background (\(app.state.rawValue))")
        sleep(1)
        app.activate()
    }

    @MainActor func testAReturnFromTheBackgroundSplashesOntoTheOpeningTabsHeader() {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_LAUNCH"] = "home"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        let splash = app.otherElements["Starting PigTV"]
        XCTAssertTrue(waitUntil(20) { !splash.exists && self.headerTitle(app) == "Sport" }, "the cold launch lands on Sport")

        openSettings(app)
        XCTAssertTrue(waitUntil(10) { self.headerTitle(app) == "Settings" }, "on Settings before leaving")
        attach(app, "foreground-reset-1-left-on-settings")

        goToTheBackgroundAndBack(app)
        XCTAssertTrue(splash.waitForExistence(timeout: 5), "the splash plays again on the return")
        attach(app, "foreground-reset-2-splash")
        // The hand-off starts at 2.0 s and the pig is mid-flight about 0.6 s later.
        Thread.sleep(forTimeInterval: 1.6)
        attach(app, "foreground-reset-3-flight")
        XCTAssertTrue(waitUntil(10) { !splash.exists }, "the splash hands over")
        XCTAssertTrue(waitUntil(5) { self.headerTitle(app) == "Sport" }, "back on the opening tab, not Settings")
        attach(app, "foreground-reset-4-landed")
    }
}
