import XCTest

#if os(tvOS)
// D-44 batch 5 (Apple 114, R5-Record-TV), remade to Mark's final design (#358): the one record page on the offline
// fixtures (DesignTestScreen, no server). PIGTV_UI_TEST_SCREEN=record (a guide programme), record-sport (a game on three
// channels, with its game id) and record-change (a scheduled programme: Set to record, Done, Cancel recording with Undo);
// PIGTV_UI_TEST_RECORD_PAGE=extra opens it on the Extra time page. Screenshots are attached (T3).
final class RecordPageUITests: XCTestCase {
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

    private func launch(_ screen: String, flip: String? = nil, page: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = screen
        if let flip { app.launchEnvironment["PIGTV_UI_TEST_RECORD_FLIP"] = flip }
        if let page { app.launchEnvironment["PIGTV_UI_TEST_RECORD_PAGE"] = page }
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["record.page"].waitForExistence(timeout: 15), "no record page")
        return app
    }

    /// Moves focus up (then down) until `id` has it.
    private func focus(_ app: XCUIApplication, _ id: String) {
        for direction in [XCUIRemote.Button.up, .down] {
            for _ in 0..<6 where focused(app).identifier != id {
                XCUIRemote.shared.press(direction)
                _ = waitUntil(1) { self.focused(app).identifier == id }
            }
        }
        XCTAssertEqual(focused(app).identifier, id)
    }

    /// A guide programme: What (this programme, every new episode, every episode) as a switch, the date once, the Channel
    /// row with nothing to choose (one channel), Extra time "Usual", no "When it stops"; focus on Record programme.
    @MainActor
    func testAProgrammeOffersWhatAndTwoRows() throws {
        let app = launch("record")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(app.buttons["record.what.this"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["record.what.this"].isSelected)
        XCTAssertTrue(app.buttons["record.what.newEpisodes"].exists && app.buttons["record.what.episodes"].exists)
        XCTAssertTrue(any["record.when"].exists, "the date and time, in the header")
        XCTAssertFalse(any["record.stop"].exists, "no When it stops")
        XCTAssertTrue(any["record.row.channel"].exists)
        XCTAssertFalse(app.buttons["record.row.channel"].exists, "one channel: the row opens nothing")
        XCTAssertTrue(app.buttons["record.row.extra"].label.hasSuffix("Usual"), app.buttons["record.row.extra"].label)
        XCTAssertTrue(waitUntil { self.focused(app).identifier == "record.schedule" }, "focus: \(focused(app).identifier)")
        XCTAssertEqual(app.buttons["record.schedule"].label, "Record programme")
        attach(app, "record-programme")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { !any["record.page"].exists }, "Back did not close the page")
    }

    /// A game on three channels: the teams' What, the Channel page (BEST first, the chosen one ticked; choosing returns
    /// to the main page) and the Extra time page (left and right step Finish late, its usual 0 for a game ESPN follows).
    @MainActor
    func testAGameOpensItsChannelAndExtraTimePages() throws {
        let app = launch("record-sport")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(app.buttons["record.row.channel"].waitForExistence(timeout: 5), "three channels: Channel opens a page")
        XCTAssertTrue(app.buttons.matching(identifier: "record.what.team").count >= 1, "every game of a side")
        XCTAssertTrue(app.buttons["record.what.league"].exists, "every game of the league")
        XCTAssertEqual(app.buttons["record.schedule"].label, "Record game")
        XCTAssertTrue(app.buttons["record.row.extra"].label.hasSuffix("Usual"))
        attach(app, "record-game")

        focus(app, "record.row.channel")
        XCUIRemote.shared.press(.select)
        let best = app.buttons["record.on.0"], other = app.buttons["record.on.1"]
        XCTAssertTrue(best.waitForExistence(timeout: 5), "the Channel page")
        XCTAssertTrue(app.buttons["record.on.2"].exists, "three channels")
        XCTAssertTrue(best.isSelected, "the best channel is chosen to start with")
        XCTAssertTrue(best.label.contains("best"), best.label)
        XCTAssertFalse(any["record.schedule"].exists, "the page replaces the main page")
        XCTAssertTrue(waitUntil { best.hasFocus }, "focus on the chosen channel: \(focused(app).identifier)")
        attach(app, "record-game-channel")
        let otherName = other.label.components(separatedBy: ",").first ?? ""
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitUntil { other.hasFocus }, "focus: \(focused(app).identifier)")
        XCUIRemote.shared.press(.select)
        let channelRow = app.buttons["record.row.channel"]
        XCTAssertTrue(channelRow.waitForExistence(timeout: 5), "choosing returns to the main page")
        XCTAssertTrue(channelRow.label.contains(otherName), "\(channelRow.label) names \(otherName)")
        XCTAssertTrue(waitUntil { channelRow.hasFocus }, "focus back on Channel: \(focused(app).identifier)")

        focus(app, "record.row.extra")
        XCUIRemote.shared.press(.select)
        let finish = app.buttons["record.after"], start = app.buttons["record.before"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5), "the Extra time page")
        XCTAssertTrue(start.exists)
        XCTAssertTrue(waitUntil { start.hasFocus }, "focus: \(focused(app).identifier)")
        XCTAssertTrue(finish.label.hasSuffix("0 min"), "Finish late's usual for a game ESPN follows: \(finish.label)")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitUntil { finish.hasFocus }, "focus: \(focused(app).identifier)")
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitUntil { finish.label.hasSuffix("1 min") }, finish.label)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(finish.label.hasSuffix("1 min"), "select changes nothing: \(finish.label)")
        XCTAssertTrue(finish.hasFocus, "select leaves the page as it is")
        attach(app, "record-game-extra")
        XCUIRemote.shared.press(.menu)
        let extraRow = app.buttons["record.row.extra"]
        XCTAssertTrue(extraRow.waitForExistence(timeout: 5), "Back returns to the main page, the sheet stays")
        XCTAssertTrue(extraRow.label.hasSuffix("1 min early, 1 min late"), extraRow.label)
        attach(app, "record-game-extra-chosen")
    }

    /// A scheduled programme opens as Set to record: Done (on at once: it closes when nothing changed) and Cancel
    /// recording, which closes the page at once and offers Undo.
    @MainActor
    func testSetToRecordHasDoneAndCancelsWithUndo() throws {
        let app = launch("record-change")
        let any = app.descendants(matching: .any)
        let done = app.buttons["record.schedule"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(done.label, "Done")
        XCTAssertTrue(done.isEnabled)
        XCTAssertTrue(any["record.state"].label.contains("Set to record"), any["record.state"].label)
        XCTAssertFalse(app.buttons["record.what.this"].exists, "one schedule: no What")
        XCTAssertFalse(app.buttons["record.row.channel"].exists, "it records where it was set")
        XCTAssertTrue(app.buttons["record.row.extra"].label.hasSuffix("2 min early, 15 min late"), app.buttons["record.row.extra"].label)
        attach(app, "record-change")
        let cancel = app.buttons["record.cancelRecording"]
        XCTAssertTrue(cancel.exists)
        XCTAssertTrue(waitUntil { done.hasFocus }, "focus starts on Done: \(focused(app).identifier)")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitUntil { cancel.hasFocus }, "focus: \(focused(app).identifier)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { !any["record.page"].exists }, "the page did not close")
        XCTAssertTrue(any["undo.toast"].waitForExistence(timeout: 5), "no Undo")
        attach(app, "record-change-cancelled-undo")
    }

    /// Codex 5a round 1 (medium): the schedule starts recording while Extra time is open. Start early becomes "Started"
    /// with no − or + (its edit would be refused); Finish late can still change; Cancel becomes Stop recording.
    @MainActor
    func testExtraTimeFollowsItsScheduleWhenItStartsRecording() throws {
        let app = launch("record-change", flip: "recording", page: "extra")
        let start = app.buttons["record.before"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Start early can change before it records")
        attach(app, "record-change-extra")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(waitUntil(10) { !start.exists }, "Start early did not lock once it recorded")
        XCTAssertTrue(any["record.before"].label.hasSuffix("Started"), any["record.before"].label)
        XCTAssertTrue(app.buttons["record.after"].exists, "Finish late can still change")
        attach(app, "record-change-extra-recording")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["record.cancelRecording"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["record.cancelRecording"].label.hasPrefix("Stop recording"), app.buttons["record.cancelRecording"].label)
        XCTAssertTrue(any["record.state"].label.contains("Recording now"), any["record.state"].label)
    }

    /// The schedule ends while the page is open: Cancel recording is off, Extra time opens nothing, and the page says why.
    @MainActor
    func testSetToRecordSaysSoWhenItsScheduleIsGone() throws {
        let app = launch("record-change", flip: "gone")
        let cancel = app.buttons["record.cancelRecording"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(10) { !cancel.isEnabled }, "Cancel recording stayed on for a schedule that is gone")
        XCTAssertFalse(app.buttons["record.row.extra"].exists, "no change to a schedule that is gone")
        XCTAssertTrue(app.staticTexts["This recording has finished or no longer exists, so it cannot be changed."].exists)
        XCTAssertTrue(app.descendants(matching: .any)["record.state"].label.contains("Ended"))
    }
}
#endif
