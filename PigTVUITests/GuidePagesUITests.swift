import XCTest

#if os(tvOS)
// D-44 batch 4 (Apple 106–110): the TV Guide's strip, chips and tools, its long-press menu, and its pages (programme
// details, the channel page, Search with Jump to), on the offline guide fixture (PIGTV_UI_TEST_SCREEN=guide; no server).
final class GuidePagesUITests: XCTestCase {
    private let tile = "Sky Sports Main Event"

    override func setUp() { continueAfterFailure = false }

    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    private func focusedLabel(_ app: XCUIApplication) -> String {
        let element = focused(app)
        return element.exists ? element.label : "<none>"
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launch(_ screen: String = "guide") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = screen
        app.launch()
        XCTAssertTrue(app.collectionViews["guide.grid"].waitForExistence(timeout: 10), "guide grid not shown")
        return app
    }

    /// Down into the grid, then Right onto a later programme in the first row.
    private func enterFirstRow(_ app: XCUIApplication) {
        for _ in 0..<8 where focusedLabel(app) != tile && !focusedLabel(app).contains(", ") {
            XCUIRemote.shared.press(.down)
        }
        if focusedLabel(app) == tile { XCUIRemote.shared.press(.right) }
    }

    private func strip(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["guide.strip"]
    }

    /// 106: the slim strip reads the focused programme (title, then times, channel, status, description), says how to
    /// reach the options, and the chips and tools share one row.
    @MainActor
    func testTheStripReadsTheFocusedProgramme() throws {
        let app = launch()
        enterFirstRow(app)
        XCUIRemote.shared.press(.right)
        let programme = focusedLabel(app)
        XCTAssertTrue(programme.hasPrefix("\(tile), "), "no programme focused: \(programme)")
        let title = String(programme.dropFirst(tile.count + 2))
        XCTAssertTrue(waitUntil { self.strip(app).exists && self.strip(app).label == title },
                      "the strip does not read the focused programme: \(strip(app).exists ? strip(app).label : "<no strip>") vs \(title)")
        XCTAssertTrue((strip(app).value as? String)?.contains(tile) == true, "the strip names no channel: \(strip(app).value ?? "")")
        XCTAssertTrue(app.staticTexts["Long press for options"].exists)
        for name in ["All", "Favourites", "Sport", "Movies", "Now", "Earlier", "Later", "Search", "Jump to…"] {
            XCTAssertTrue(app.buttons[name].exists, "no \(name) in the chip row")
        }
        XCTAssertFalse(app.buttons["Sports"].exists, "the lone sport category is listed twice")
        let row = app.buttons["All"].frame.midY
        XCTAssertEqual(app.buttons["Jump to…"].frame.midY, row, accuracy: 4, "the tools are not on the chips' row")
        XCUIRemote.shared.press(.down)
        let below = focusedLabel(app)
        let belowTitle = below.components(separatedBy: ", ").dropFirst().joined(separator: ", ")
        XCTAssertTrue(waitUntil { self.strip(app).label == belowTitle },
                      "the strip did not follow focus down: \(strip(app).label) vs \(below)")
        attach(app, "Guide strip")
    }

    /// 107: a long press opens PigTV's menu card beside the programme (not the system menu), RECORD first with focus on
    /// Record this programme; Back closes it and focus is on the programme again.
    @MainActor
    func testLongPressOpensTheMenuCardBesideTheProgramme() throws {
        let app = launch()
        enterFirstRow(app)
        XCUIRemote.shared.press(.right)
        let programme = focusedLabel(app)
        let cell = focused(app).frame
        XCTAssertTrue(programme.hasPrefix("\(tile), "), "no programme focused: \(programme)")
        XCUIRemote.shared.press(.select, forDuration: 1.5)
        let record = app.buttons["menu.recordThis"]
        XCTAssertTrue(record.waitForExistence(timeout: 3), "no menu card")
        XCTAssertTrue(waitUntil { record.hasFocus }, "focus is not on Record this programme: \(focusedLabel(app))")
        let order = ["menu.recordThis", "menu.moreOptions", "menu.details", "menu.schedule", "menu.favourite"]
        let tops = order.map { app.buttons[$0].frame.minY }
        XCTAssertEqual(tops, tops.sorted(), "the menu is out of order: \(order) at \(tops)")
        XCTAssertFalse(record.frame.intersects(cell), "the card covers the programme")
        XCTAssertTrue(app.staticTexts["RECORD"].exists)
        attach(app, "Guide menu card")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { !record.exists }, "Back did not close the card")
        XCTAssertTrue(waitUntil { self.focusedLabel(app) == programme }, "focus did not return to the programme: \(focusedLabel(app))")
    }

    /// 108 (#49): Select on a later programme pushes its page (hero, Record as the primary, Also on <channel>); Back
    /// pops it and focus is on the programme again, with no timed retries.
    @MainActor
    func testProgrammeDetailsIsAPageAndBackReturnsFocusToTheProgramme() throws {
        let app = launch()
        enterFirstRow(app)
        XCUIRemote.shared.press(.right)
        let programme = focusedLabel(app)
        XCTAssertTrue(programme.hasPrefix("\(tile), "), "no programme focused: \(programme)")
        XCUIRemote.shared.press(.select)
        let record = app.buttons["details.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5), "no programme page")
        XCTAssertTrue(waitUntil { record.hasFocus }, "Record is not focused: \(focusedLabel(app))")
        let alsoOn = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Also on \(tile)")).firstMatch
        XCTAssertTrue(alsoOn.exists, "no Also on \(tile) list")
        attach(app, "Programme page")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { !record.exists }, "Back did not leave the page")
        XCTAssertTrue(waitUntil { self.focusedLabel(app) == programme }, "focus did not return to the programme: \(focusedLabel(app))")
    }
}
#endif
