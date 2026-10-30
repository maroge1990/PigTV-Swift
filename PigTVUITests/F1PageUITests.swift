import XCTest

#if os(tvOS)
// C-P (#21): the Formula 1 page on its offline fixture (PIGTV_UI_TEST_SCREEN=f1 | f1-live; no server). The remote
// reaches the spoiler chip, which hides the results and the standings; the live weekend offers Watch live. Screenshots
// are attached for review (T3 evidence for the approved mock-ups).
final class F1PageUITests: XCTestCase {
    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = screen
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        return app
    }

    @MainActor
    func testTheSpoilerChipHidesResultsAndStandings() throws {
        let app = launch("f1")
        XCTAssertTrue(app.staticTexts["f1.weekend"].waitForExistence(timeout: 10), "the F1 page did not open")
        XCTAssertTrue(app.staticTexts["Kimi Antonelli"].exists, "results and standings are shown")
        attach(app, "f1-before")
        // Up to the header, then right to the spoiler chip.
        for _ in 0..<4 where focused(app).identifier != "f1.spoilers" {
            XCUIRemote.shared.press(.up)
        }
        for _ in 0..<3 where focused(app).identifier != "f1.spoilers" {
            XCUIRemote.shared.press(.right)
        }
        XCTAssertEqual(focused(app).identifier, "f1.spoilers")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Results hidden"].waitForExistence(timeout: 5), "spoiler-free did not hide the results")
        XCTAssertTrue(app.staticTexts["Standings hidden"].exists)
        XCTAssertFalse(app.staticTexts["Kimi Antonelli"].exists, "no driver's name is left on screen")
        attach(app, "f1-spoiler-free")
    }

    @MainActor
    func testTheLiveRaceOffersWatchLive() throws {
        let app = launch("f1-live")
        XCTAssertTrue(app.buttons["f1.watch"].waitForExistence(timeout: 10), "no Watch live while the race is on")
        XCTAssertTrue(app.buttons["f1.channels"].exists, "the race is on two channels")
        XCTAssertTrue(app.staticTexts["LIVE"].exists)
        attach(app, "f1-live")
    }
}
#endif
