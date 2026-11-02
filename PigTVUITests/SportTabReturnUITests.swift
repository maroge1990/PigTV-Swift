import XCTest

#if os(tvOS)
/// #214 (Apple 103): the Sport tab returns to its front page. On the D-43 pages fixture (a sport page opened over the
/// front page, as a rail header would), moving along the tab bar to the TV Guide and back to Sport shows the front
/// page, not the sport page left behind; and selecting Sport again while on a sport page does too.
final class SportTabReturnUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    private func launch() throws -> XCUIApplication {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PigTVTests/Fixtures/sport-pages-d43.json")
        let json = try Data(contentsOf: fixture)
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "front"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launchEnvironment["PIGTV_UI_TEST_OPEN_SPORT"] = "Motorsport"
        app.launchEnvironment["PIGTV_UI_TEST_PAGES_JSON"] = json.base64EncodedString()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["sport.page.Motorsport"].waitForExistence(timeout: 15), "the sport page")
        return app
    }

    /// Up until the tab bar has focus.
    private func upToTheTabBar(_ app: XCUIApplication) {
        let bar = app.tabBars.firstMatch
        for _ in 0..<10 {
            let frame = focused(app).frame
            if focused(app).exists, frame.maxY <= bar.frame.maxY + 1, frame.height > 0 { return }
            XCUIRemote.shared.press(.up)
        }
        XCTFail("focus never reached the tab bar: \(focused(app).debugDescription)")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func testComingBackToSportShowsTheFrontPage() throws {
        let app = try launch()
        let any = app.descendants(matching: .any)
        upToTheTabBar(app)
        XCUIRemote.shared.press(.right) // TV Guide
        XCTAssertTrue(waitUntil(10) { !any["sport.page.Motorsport"].exists || !any["sport.page.Motorsport"].isHittable },
                      "the TV Guide is shown")
        XCUIRemote.shared.press(.left) // Sport again
        XCTAssertTrue(any["sport.front"].waitForExistence(timeout: 10), "back on Sport")
        XCTAssertTrue(waitUntil(5) { !any["sport.page.Motorsport"].exists }, "the front page, not the sport page left behind")
        attach(app, "sport-tab-return")
    }
}
#endif
