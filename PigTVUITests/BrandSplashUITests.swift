import XCTest

#if os(tvOS)
// The branded start-up view (PIGTV_UI_TEST_SCREEN=splash keeps it on screen): it draws, and its slow-start
// progress indicator stays out of the way for the first two seconds.
final class BrandSplashUITests: XCTestCase {
    @MainActor
    func testSplashShowsTheBrandedStartView() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "splash"
        app.launch()
        XCTAssertTrue(app.otherElements["Starting PigTV"].waitForExistence(timeout: 10), "the splash is not shown")
        sleep(2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "splash"; shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif
