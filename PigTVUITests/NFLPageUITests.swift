import XCTest

#if os(tvOS)
// C-Q (#21, Apple 86): the NFL page on the server's own answer (PigTVTests/Fixtures/nfl-page-0379.json, read from the
// source tree: simulator runs are on the Mac) with no server. It opens on the current week; the week chips switch to the
// one before; following the Packers puts their card and division first; spoiler-free hides scores and standings.
// Screenshots are attached for review against the approved mock-up (T3).
final class NFLPageUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launch(_ screen: String) throws -> XCUIApplication {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PigTVTests/Fixtures/nfl-page-0379.json")
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = screen
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launchEnvironment["PIGTV_UI_TEST_NFL_JSON"] = try Data(contentsOf: fixture).base64EncodedString()
        app.launch()
        return app
    }

    @MainActor
    func testTheWeeksAndTheStandings() throws {
        let app = try launch("nfl")
        XCTAssertTrue(app.buttons["nfl.week.8"].waitForExistence(timeout: 10), "the NFL page did not open")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Bye:'")).firstMatch.exists, "the byes")
        XCTAssertTrue(app.staticTexts["27"].exists, "Thursday's final score")
        attach(app, "nfl-week-8")
        // To the week chips (below the header), then left to Week 7.
        for _ in 0..<6 where !focused(app).identifier.hasPrefix("nfl.week.") {
            XCUIRemote.shared.press(focused(app).identifier.hasPrefix("nfl.") && !focused(app).identifier.hasPrefix("nfl.game.") ? .down : .up)
        }
        for _ in 0..<3 where focused(app).identifier != "nfl.week.7" { XCUIRemote.shared.press(.left) }
        XCTAssertEqual(focused(app).identifier, "nfl.week.7")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil(5) { app.staticTexts["24"].exists }, "week 7's finals")
        attach(app, "nfl-week-7")
    }

    @MainActor
    func testFollowingTheTeamAndSpoilerFree() throws {
        var app = try launch("nfl-following")
        XCTAssertTrue(app.staticTexts["Green Bay Packers"].waitForExistence(timeout: 10), "the followed team's card")
        XCTAssertTrue(app.staticTexts["NFC NORTH"].exists, "its division first")
        attach(app, "nfl-following-packers")
        app.terminate()
        app = try launch("nfl-spoilers")
        XCTAssertTrue(app.staticTexts["Standings hidden"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["27"].exists, "no score with spoiler-free on")
        attach(app, "nfl-spoiler-free")
    }
}
#endif
