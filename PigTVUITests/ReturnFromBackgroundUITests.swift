import XCTest

/// A return from the background shows PigTV exactly where it was left (Mark, 19 Nov 2026, reversing Apple 320's reset):
/// the same tab and page, no splash. Only a cold launch plays the splash. PIGTV_UI_TEST_LAUNCH=home: the real start-up
/// path (ContentView) with a saved sign-in that lands on the fixture. On Apple 320-324 the return replayed the splash and
/// went back to Sport, so this fails there.
final class ReturnFromBackgroundUITests: XCTestCase {
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

    @MainActor func testAReturnFromTheBackgroundKeepsThePageAndPlaysNoSplash() {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_LAUNCH"] = "home"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        let splash = app.otherElements["Starting PigTV"]
        XCTAssertTrue(waitUntil(20) { !splash.exists && self.headerTitle(app) == "Sport" }, "the cold launch lands on Sport")

        openSettings(app)
        XCTAssertTrue(waitUntil(10) { self.headerTitle(app) == "Settings" }, "on Settings before leaving")
        attach(app, "return-1-left-on-settings")

        goToTheBackgroundAndBack(app)
        XCTAssertTrue(waitUntil(10) { app.state == .runningForeground }, "back in front")
        // The splash's hand-off would take 3.2 s: watch past it, polling, so a splash that appears at all is caught.
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            XCTAssertFalse(splash.exists, "no splash on a return from the background")
            Thread.sleep(forTimeInterval: 0.2)
        }
        attach(app, "return-2-back")
        XCTAssertEqual(headerTitle(app), "Settings", "still on the page that was left, not the opening tab")
    }
}
