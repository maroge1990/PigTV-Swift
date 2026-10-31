import XCTest

#if os(tvOS)
// C-S (#21, Apple 90): the Cricket page on the server's own answer (PigTVTests/Fixtures/cricket-page-0387-live.json, read
// from the source tree: simulator runs are on the Mac) with no server, opened from the Sport front page's Cricket tile
// (PigTVTests/Fixtures/sport-front-0381.json). The lead's best channel is moved to air now, so "Watch live" is offered
// and focused; pressing it reaches the player, which tunes (its resolve goes to a TEST-NET address). Screenshots are
// attached for review against the mock-up (T3).
final class CricketPageUITests: XCTestCase {
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

    private func launch() throws -> XCUIApplication {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PigTVTests/Fixtures")
        // The lead's Fox Cricket airing around now (the answer was made on 31 Oct 2026 at 01:56 UTC).
        var cricket = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("cricket-page-0387-live.json"))) as? [String: Any])
        var lead = try XCTUnwrap(cricket["lead"] as? [String: Any])
        var channels = try XCTUnwrap(lead["channels"] as? [[String: Any]])
        let now = Date().timeIntervalSince1970 * 1000
        channels[0]["start"] = now - 3_600_000
        channels[0]["end"] = now + 3 * 3_600_000
        lead["channels"] = channels
        cricket["lead"] = lead
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "front"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launchEnvironment["PIGTV_UI_TEST_FRONT_JSON"] = try Data(contentsOf: fixtures.appendingPathComponent("sport-front-0381.json")).base64EncodedString()
        app.launchEnvironment["PIGTV_UI_TEST_CRICKET_JSON"] = try JSONSerialization.data(withJSONObject: cricket).base64EncodedString()
        app.launch()
        return app
    }

    @MainActor
    func testTheCricketTileOpensThePageAndWatchLivePlays() throws {
        let app = try launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.front"].waitForExistence(timeout: 15), "the app did not open on the Sport front page")
        let tile = any["sport.front.tile.Cricket"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "the Cricket tile")
        // From the tab bar down to the tiles, then along to Cricket.
        for _ in 0..<12 where focused(app).identifier != "sport.front.tile.Cricket" {
            let id = focused(app).identifier
            XCUIRemote.shared.press(id.hasPrefix("sport.front.tile.") ? .right : id.hasPrefix("sport.front.") ? .up : .down)
        }
        XCTAssertEqual(focused(app).identifier, "sport.front.tile.Cricket")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(any["cricket.page"].waitForExistence(timeout: 10), "the Cricket page did not open")
        let title = any["cricket.lead.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "South Africa v Australia")
        XCTAssertTrue(app.staticTexts["3RD TEST · DAY 4 · SESSION 3"].exists, "the kicker")
        XCTAssertTrue(any.matching(NSPredicate(format: "label CONTAINS '329 & 294/5'")).firstMatch.exists, "South Africa's innings")
        XCTAssertTrue(app.staticTexts["Rickelton 101* · Mulder 115*"].exists, "the crease")
        XCTAssertTrue(any["cricket.following"].exists, "Following Australia")
        XCTAssertTrue(any["cricket.day.4.live"].exists && any["cricket.day.5.next"].exists, "the day chips")
        XCTAssertTrue(any["cricket.series.1525661"].exists, "the series, the current match")
        let watch = app.buttons["cricket.action.watch"]
        XCTAssertTrue(watch.waitForExistence(timeout: 5), "Watch live")
        XCTAssertTrue(app.buttons["cricket.action.channels"].exists, "Other channels")
        attach(app, "cricket-live")

        for _ in 0..<6 where focused(app).identifier != "cricket.action.watch" {
            let id = focused(app).identifier
            XCUIRemote.shared.press(id.hasPrefix("cricket.action.") ? .left : id.hasPrefix("cricket.other.") ? .up : .down)
        }
        XCTAssertEqual(focused(app).identifier, "cricket.action.watch")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Tuning…"].waitForExistence(timeout: 10), "Watch live reached the player")
    }
}
#endif
