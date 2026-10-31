import XCTest

#if os(tvOS)
// C-R (#21, D-39, Apple 89): the Sport front page on the server's own answer (PigTVTests/Fixtures/sport-front-0381.json,
// read from the source tree: simulator runs are on the Mac), inside the app's tab bar with no server. The app opens on
// Sport; the tab bar reads Sport · TV · TV Guide · Recordings · Settings; the page shows the hero, the follows and a rail
// per followed sport; selecting the other follow flips the hero. Screenshots are attached for review (T3).
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

    private func launch() throws -> XCUIApplication {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PigTVTests/Fixtures/sport-front-0381.json")
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "front"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launchEnvironment["PIGTV_UI_TEST_FRONT_JSON"] = try Data(contentsOf: fixture).base64EncodedString()
        app.launch()
        return app
    }

    @MainActor
    func testTheAppOpensOnTheFrontPageAndAFollowFlipsTheHero() throws {
        let app = try launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.front"].waitForExistence(timeout: 15), "the app did not open on the Sport front page")
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map(\.label), ["Sport", "TV", "TV Guide", "Recordings", "Settings"])
        // The Sport tab is the one shown: its page header, and (focus starts in the tab bar) its tab item. A tvOS tab item
        // does not always report isSelected, so focus counts too.
        let sportTab = app.tabBars.buttons["Sport"]
        XCTAssertTrue(waitUntil(5) { sportTab.isSelected || sportTab.hasFocus }, "Sport is the selected tab")
        XCTAssertTrue(app.staticTexts.matching(identifier: "page.header.title").matching(NSPredicate(format: "label == 'Sport'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["home.watch"].exists, "not on TV")
        XCTAssertTrue(any["sport.front.hero"].exists)
        XCTAssertTrue(any["sport.front.follow.0"].exists && any["sport.front.follow.1"].exists, "both follows")
        for league in ["F1", "NFL", "NBA", "Cricket"] {
            XCTAssertTrue(any["sport.front.rail.\(league)"].exists, "the \(league) rail")
        }
        let title = any["sport.front.hero.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the hero's title")
        XCTAssertTrue(waitUntil(5) { title.label == "Packers v Bears" }, "the server's hero, the followed Packers live: \(title.label)")
        attach(app, "sport-front")

        // Into the page and over to the follows on the right (the hero may have no buttons: the fixture's live game has
        // no channel): along the tiles to "Follow a sport", which sits above the follows, then down. Then onto the other
        // follow (Oscar Piastri) and select it.
        for _ in 0..<14 where !focused(app).identifier.hasPrefix("sport.front.follow.") {
            let id = focused(app).identifier
            let button: XCUIRemote.Button
            if id == "sport.front.addSport" { button = .down }
            else if id.hasPrefix("sport.front.tile.") || id.hasPrefix("sport.front.hero.") { button = .right }
            else if id.hasPrefix("sport.front.game.") { button = .up }
            else { button = .down }
            XCUIRemote.shared.press(button)
        }
        XCTAssertTrue(focused(app).identifier.hasPrefix("sport.front.follow."), "focus: \(focused(app).identifier)")
        for _ in 0..<3 where focused(app).identifier != "sport.front.follow.0" { XCUIRemote.shared.press(.up) }
        XCTAssertEqual(focused(app).identifier, "sport.front.follow.0")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil(5) { title.label == "Mexico City Grand Prix" }, "the hero flipped: \(title.label)")
        attach(app, "sport-front-flipped")
    }
}
#endif
