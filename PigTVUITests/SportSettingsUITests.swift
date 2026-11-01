import XCTest

#if os(tvOS)
// #200 (C-U): Settings › Sport on the offline fixture (PIGTV_UI_TEST_SCREEN=settings-sport): the section shows a
// suggestion, the spoiler-free switch and the followed sports, and a sport opens its page with the remote.
// PIGTV_SCREENSHOT_DIR (passed as TEST_RUNNER_PIGTV_SCREENSHOT_DIR) also saves the screenshots there.
final class SportSettingsUITests: XCTestCase {
    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        if let directory = ProcessInfo.processInfo.environment["PIGTV_SCREENSHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    @MainActor
    func testTheSectionShowsTheFollowsAndOpensASport() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "settings-sport"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        let football = app.buttons["settings.sport.row.Football"]
        XCTAssertTrue(football.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["settings.sport.row.Cricket"].exists)
        XCTAssertTrue(app.buttons["settings.sport.suggestion.add.League Cup"].exists, "the league suggestion offers Add")
        XCTAssertTrue(app.buttons["settings.sport.suggestion.decline.League Cup"].exists, "and No thanks")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'League Cup has Arsenal games too'")).firstMatch.exists)
        let spoilers = app.buttons["settings.sport.spoilerFree"]
        XCTAssertTrue(spoilers.exists)
        XCTAssertEqual(spoilers.value as? String, "On")
        XCTAssertTrue(app.buttons["settings.sport.add"].exists, "Add a sport")

        var reached = false
        for _ in 0..<14 {
            if football.hasFocus { reached = true; break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(reached, "focus never reached Football: \(focused(app).identifier)")
        attach(app, "settings-sport-section")
        XCUIRemote.shared.press(.select)

        let up = app.buttons["settings.sport.moveUp"]
        XCTAssertTrue(up.waitForExistence(timeout: 5), "the sport's page did not open")
        XCTAssertTrue(app.buttons["settings.sport.stop"].exists)
        XCTAssertTrue(app.buttons["settings.sport.league.Champions League.remove"].exists, "its leagues")
        XCTAssertTrue(app.buttons["settings.sport.addLeague.League Cup"].exists, "Add a league")
        XCTAssertEqual(app.buttons["settings.sport.name.Arsenal.record"].value as? String, "On", "Record every game")
        XCTAssertEqual(app.buttons["settings.sport.name.Liverpool.record"].value as? String, "Off")
        XCTAssertTrue(app.buttons["settings.sport.name.Liverpool.unfollow"].exists)
        XCTAssertTrue(app.buttons["settings.sport.follow"].exists, "Follow a team…")
        attach(app, "settings-sport-football")

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(football.waitForExistence(timeout: 5), "Menu goes back to Settings")
    }
}
#endif
