import XCTest

#if os(tvOS)
// The branded start-up view (brand 1.6; PIGTV_UI_TEST_SCREEN=splash keeps it on screen): the canvas, the pig with its
// halo, the wordmark fading in and the halo breathing. The fixture never ends start-up, so the view must stay up through
// a whole breathing half-cycle (4 s); its slow-start progress indicator appears after two seconds.
final class BrandSplashUITests: XCTestCase {
    private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "splash"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = mode
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testSplashShowsTheBrandedStartViewInBothAppearances() throws {
        for mode in ["light", "dark"] {
            let app = launch(mode)
            let splash = app.otherElements["Starting PigTV"]
            XCTAssertTrue(splash.waitForExistence(timeout: 10), "the splash is not shown (\(mode))")
            attach(app, "splash-first-\(mode)")
            // Mid-cycle: the halo has faded toward 25% and the bloom is up; the view is still the splash and has not moved on.
            sleep(5)
            XCTAssertTrue(splash.exists, "the splash went away by itself (\(mode))")
            attach(app, "splash-mid-\(mode)")
            app.terminate()
        }
    }
}
#endif
