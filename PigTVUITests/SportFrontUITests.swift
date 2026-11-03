import XCTest

#if os(tvOS)
// C-R (#21, D-39, Apple 89): the Sport front page on the server's own answer (PigTVTests/Fixtures/sport-front-0381.json,
// read from the source tree: simulator runs are on the Mac), inside the app's tab bar with no server. The app opens on
// Sport; the tab bar reads Sport · TV Guide · Recordings · Settings (#216, D-44: no TV tab); the page shows the banner (the hero and the
// follows, D-43) and a rail per followed sport; selecting the other follow flips the hero. Screenshots are attached for
// review (T3).
final class SportFrontUITests: XCTestCase {
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

    private func launch(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> XCUIApplication {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PigTVTests/Fixtures/sport-front-0381.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        change(&json)
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "front"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launchEnvironment["PIGTV_UI_TEST_FRONT_JSON"] = try JSONSerialization.data(withJSONObject: json).base64EncodedString()
        app.launch()
        return app
    }

    @MainActor
    func testTheAppOpensOnTheFrontPageAndAFollowFlipsTheHero() throws {
        let app = try launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.front"].waitForExistence(timeout: 15), "the app did not open on the Sport front page")
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map(\.label), ["Sport", "TV Guide", "Recordings", "Settings"])
        // The Sport tab is the one shown: its page header, and (focus starts in the tab bar) its tab item. A tvOS tab item
        // does not always report isSelected, so focus counts too.
        let sportTab = app.tabBars.buttons["Sport"]
        XCTAssertTrue(waitUntil(5) { sportTab.isSelected || sportTab.hasFocus }, "Sport is the selected tab")
        XCTAssertTrue(any["sport.banner.hero"].exists)
        XCTAssertTrue(any["sport.banner.item.0"].exists && any["sport.banner.item.1"].exists, "both follows")
        for league in ["F1", "NFL", "NBA", "Cricket"] {
            XCTAssertTrue(any["sport.front.rail.\(league)"].exists, "the \(league) rail")
        }
        let title = any["sport.banner.hero.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the hero's title")
        XCTAssertTrue(waitUntil(5) { title.label == "Packers v Bears" }, "the server's hero, the followed Packers live: \(title.label)")
        attach(app, "sport-front")

        // Into the banner and over to the follows on the right (the fixture's live game has no channel: the hero offers
        // only its sport's page). Then onto the other follow (Oscar Piastri) and select it.
        for _ in 0..<14 where !focused(app).identifier.hasPrefix("sport.banner.item.") {
            let id = focused(app).identifier
            let button: XCUIRemote.Button
            if id.hasPrefix("sport.banner.") { button = .right }
            else if id.hasPrefix("sport.front.game.") || id.hasPrefix("sport.rail.header.") { button = .up }
            else { button = .down }
            XCUIRemote.shared.press(button)
        }
        XCTAssertTrue(focused(app).identifier.hasPrefix("sport.banner.item."), "focus: \(focused(app).identifier)")
        for _ in 0..<3 where focused(app).identifier != "sport.banner.item.0" { XCUIRemote.shared.press(.up) }
        XCTAssertEqual(focused(app).identifier, "sport.banner.item.0")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil(5) { title.label == "Mexico City Grand Prix" }, "the hero flipped: \(title.label)")
        attach(app, "sport-front-flipped")
    }

    /// #204 (maroge1990/PigTV#204), Apple 114: Record in the hero opens the record page, whose Record on lists every
    /// channel carrying the game, best first, each with its own times; choosing the second selects it (no channel
    /// dialog). The game's card id goes with it, so When it stops is the game's end (ESPN). The Packers game gets two channels whose
    /// airings are placed around the real clock (the fixture's own times are in the past by the time this runs).
    @MainActor
    func testRecordOffersEveryChannelBestFirst() throws {
        let now = Date().timeIntervalSince1970 * 1000
        let app = try launch { json in
            var games = json["games"] as? [[String: Any]] ?? []
            for index in games.indices where games[index]["id"] as? String == "espn:football/nfl:401" {
                games[index]["channels"] = [
                    ["sourceId": 1, "id": "espn-hd", "name": "ESPN HD", "start": now - 600_000, "end": now + 3 * 3_600_000],
                    ["sourceId": 2, "id": "fox-footy", "name": "Fox Footy", "start": now + 3_600_000, "end": now + 4 * 3_600_000],
                ]
            }
            json["games"] = games
        }
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.front"].waitForExistence(timeout: 15), "the Sport front page")
        XCTAssertTrue(app.buttons["sport.banner.hero.record"].waitForExistence(timeout: 5), "the hero's Record")
        for _ in 0..<8 where !focused(app).identifier.hasPrefix("sport.banner.hero.") {
            XCUIRemote.shared.press(focused(app).identifier.hasPrefix("sport.banner.item.") ? .left : .down)
        }
        for _ in 0..<3 where focused(app).identifier != "sport.banner.hero.watch" { XCUIRemote.shared.press(.left) }
        for _ in 0..<3 where focused(app).identifier != "sport.banner.hero.record" { XCUIRemote.shared.press(.right) }
        XCTAssertEqual(focused(app).identifier, "sport.banner.hero.record")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["record.page"].waitForExistence(timeout: 5), "the record page")
        XCTAssertFalse(app.staticTexts["Record on which channel?"].exists, "no channel dialog")
        let best = app.buttons["record.on.0"], other = app.buttons["record.on.1"]
        XCTAssertTrue(best.waitForExistence(timeout: 5), "Record on lists the best channel")
        XCTAssertTrue(best.label.hasPrefix("ESPN HD, Best channel"), best.label)
        XCTAssertTrue(other.label.hasPrefix("Fox Footy, "), other.label)
        XCTAssertLessThan(best.frame.minY, other.frame.minY, "best first")
        XCTAssertTrue(best.isSelected, "the best channel is chosen to start with")
        XCTAssertTrue(app.descendants(matching: .any)["record.stop"].label.hasPrefix("When the game ends (ESPN)"),
                      "the card's game: it stops when the game ends")
        XCTAssertTrue(waitUntil { self.focused(app).identifier == "record.schedule" }, "focus on Record game: \(focused(app).identifier)")
        attach(app, "sport-front-record-page")
        for _ in 0..<12 where !other.hasFocus { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(other.hasFocus, "Fox Footy: \(focused(app).identifier)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { other.isSelected && !best.isSelected }, "Fox Footy is chosen")
        attach(app, "sport-front-record-page-second-channel")
    }

    /// C-R since 0415 (#198; maroge1990/PigTV#200): a card with a recording that loses its clash shows "Set to record"
    /// and "Clashes with …" (the Chiefs game, with spoilers shown or not: it is not a score).
    @MainActor
    func testACardShowsItsRecordingAndTheClash() throws {
        let id = "espn:football/nfl:406"
        let app = try launch { json in
            var games = json["games"] as? [[String: Any]] ?? []
            for index in games.indices where games[index]["id"] as? String == id {
                games[index]["recording"] = ["scheduleId": 93, "status": "scheduled", "ruleId": 4, "clashesWith": ["Evening Match"]]
            }
            json["games"] = games
        }
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.front"].waitForExistence(timeout: 15), "the Sport front page")
        let card = any["sport.front.game.\(id)"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), "the Chiefs card")
        let mark = any["sport.card.recording.\(id)"]
        let shown = mark.exists ? mark.label : card.label
        XCTAssertTrue(shown.contains("Set to record") && shown.contains("Clashes with Evening Match"), "the card's recording: \(shown)")
        XCTAssertFalse(any["sport.front.game.espn:football/nfl:401"].label.contains("Set to record"), "only the recorded game")
        for _ in 0..<12 where focused(app).identifier != "sport.front.game.\(id)" {
            let current = focused(app).identifier
            XCUIRemote.shared.press(current.hasPrefix("sport.front.game.espn:football/nfl") ? .right : .down)
        }
        attach(app, "sport-front-recording-clash")
    }
}
#endif
