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

    private func launch(_ screen: String = "guide", search: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = screen
        if let search { app.launchEnvironment["PIGTV_UI_TEST_SEARCH"] = search }
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

    /// 114: the menu's More options… opens the record page (not the old Record sheet): What, When it stops, focus on
    /// Record programme; Back closes it.
    @MainActor
    func testMoreOptionsOpensTheRecordPage() throws {
        let app = launch()
        enterFirstRow(app)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select, forDuration: 1.5)
        let more = app.buttons["menu.moreOptions"]
        XCTAssertTrue(more.waitForExistence(timeout: 3), "no menu card")
        for _ in 0..<4 where !more.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(more.hasFocus, "focus: \(focusedLabel(app))")
        XCUIRemote.shared.press(.select)
        let page = app.descendants(matching: .any)["record.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 5), "no record page")
        XCTAssertTrue(app.buttons["record.what.this"].exists && app.descendants(matching: .any)["record.stop"].exists)
        XCTAssertTrue(waitUntil { app.buttons["record.schedule"].hasFocus }, "focus: \(focusedLabel(app))")
        attach(app, "Guide record page")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { !page.exists }, "Back did not close the page")
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

    /// 109: the menu's Channel schedule pushes the one channel page (hero with Watch live and the favourite, UP NEXT,
    /// then the days); "Channel and favourites" is gone; Back returns focus to the programme.
    @MainActor
    func testChannelScheduleOpensTheChannelPage() throws {
        let app = launch()
        enterFirstRow(app)
        let programme = focusedLabel(app)
        XCUIRemote.shared.press(.select, forDuration: 1.5)
        let schedule = app.buttons["menu.schedule"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 3), "no menu card")
        for _ in 0..<6 where !schedule.hasFocus { XCUIRemote.shared.press(.down) }
        XCUIRemote.shared.press(.select)
        let watch = app.buttons["channel.watch"]
        XCTAssertTrue(watch.waitForExistence(timeout: 5), "no channel page")
        XCTAssertTrue(waitUntil { watch.hasFocus }, "Watch live is not focused: \(focusedLabel(app))")
        XCTAssertTrue(app.staticTexts["UP NEXT"].exists, "no Up next")
        XCTAssertTrue(app.buttons["details.favourite"].exists, "no favourite on the channel page")
        XCTAssertTrue(app.staticTexts["Today"].exists || app.staticTexts["Tomorrow"].exists, "no days list")
        XCTAssertFalse(app.buttons["Channel and favourites"].exists)
        attach(app, "Channel page")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { !watch.exists }, "Back did not leave the page")
        XCTAssertTrue(waitUntil { self.focusedLabel(app) == programme }, "focus did not return to the programme: \(focusedLabel(app))")
    }

    /// 110 (#57's Apple half): Search and Jump to are one page, side by side; a search finds programmes in the loaded
    /// guide, and a result opens that programme's page (Back returns to the search).
    @MainActor
    func testSearchAndJumpToShareOnePageAndAResultOpensItsProgramme() throws {
        let app = launch(search: "Highlights")
        enterFirstRow(app)
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitUntil { self.focusedLabel(app) == "Now" }, "Up did not reach Now: \(focusedLabel(app))")
        for _ in 0..<6 where focusedLabel(app) != "Search" { XCUIRemote.shared.press(.right) }
        XCUIRemote.shared.press(.select)
        let field = app.descendants(matching: .any)["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search page")
        let show = app.buttons["Show guide"]
        XCTAssertTrue(show.exists, "Jump to is not on the search page")
        XCTAssertLessThan(field.frame.maxX, show.frame.minX, "Search and Jump to are not side by side")
        let heading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Programmes · next 24 hours · ")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5), "no programme results")
        XCTAssertNotEqual(heading.label, "Programmes · next 24 hours · 0")
        attach(app, "Search page")
        var path: [String] = []
        for _ in 0..<6 where !focusedLabel(app).hasPrefix("Highlights") { XCUIRemote.shared.press(.down); path.append(focusedLabel(app)) }
        let result = focusedLabel(app)
        XCTAssertTrue(result.hasPrefix("Highlights"), "could not reach a result: \(path)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { app.buttons["details.record"].exists || app.buttons["Watch live"].exists }, "the result did not open its page")
        XCTAssertTrue(app.staticTexts[String(result.prefix { $0 != "," })].exists, "the page is not the result's programme")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { field.exists && self.focusedLabel(app) == result }, "Back did not return to the result: \(focusedLabel(app))")
    }
}
#endif
