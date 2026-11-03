import XCTest

#if os(tvOS)
// D-44 batch 5 (Apple 114, R5-Record-TV): the one record page on the offline fixtures (DesignTestScreen, no server).
// PIGTV_UI_TEST_SCREEN=record (a guide programme), record-sport (a game on three channels, with its game id) and
// record-change (a scheduled programme: Change recording, Cancel recording with Undo). Screenshots are attached (T3).
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

    private func launch(_ screen: String, flip: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = screen
        if let flip { app.launchEnvironment["PIGTV_UI_TEST_RECORD_FLIP"] = flip }
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["record.page"].waitForExistence(timeout: 15), "no record page")
        return app
    }

    /// A guide programme: What (this programme, every new episode, every episode), When it stops (the guide end) with
    /// Start early / Finish late ("Usual" first, chosen), no Record on (one channel); focus on Record programme.
    @MainActor
    func testAProgrammeOffersWhatAndWhenItStops() throws {
        let app = launch("record")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(app.buttons["record.what.this"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["record.what.this"].isSelected)
        XCTAssertTrue(any["record.stop"].label.hasPrefix("When the guide says it ends"), any["record.stop"].label)
        XCTAssertTrue(app.buttons["record.before.usual"].isSelected && app.buttons["record.after.usual"].isSelected)
        XCTAssertFalse(app.buttons["record.on.0"].exists, "one channel: no Record on")
        XCTAssertTrue(waitUntil { self.focused(app).identifier == "record.schedule" }, "focus: \(focused(app).identifier)")
        XCTAssertEqual(app.buttons["record.schedule"].label, "Record programme")
        attach(app, "record-programme")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { !any["record.page"].exists }, "Back did not close the page")
    }

    /// A game on three channels: the teams' What, When the game ends (ESPN), Record on with the best first and chosen.
    @MainActor
    func testAGameOffersItsTeamsItsEndAndItsChannels() throws {
        let app = launch("record-sport")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(app.buttons["record.on.2"].waitForExistence(timeout: 5), "three channels")
        XCTAssertTrue(app.buttons["record.on.0"].isSelected)
        XCTAssertTrue(app.buttons["record.on.0"].label.contains("Best channel"), app.buttons["record.on.0"].label)
        XCTAssertTrue(any["record.stop"].label.hasPrefix("When the game ends (ESPN)"), any["record.stop"].label)
        XCTAssertTrue(app.buttons.matching(identifier: "record.what.team").count >= 1, "every game of a side")
        XCTAssertTrue(app.buttons["record.what.league"].exists, "every game of the league")
        XCTAssertEqual(app.buttons["record.schedule"].label, "Record game")
        attach(app, "record-game")
    }

    /// A scheduled programme opens as Change recording: Save changes only once something changed; Cancel recording
    /// closes the page at once and offers Undo.
    @MainActor
    func testChangeRecordingSavesChangesAndCancelsWithUndo() throws {
        let app = launch("record-change")
        let any = app.descendants(matching: .any)
        let save = app.buttons["record.schedule"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertEqual(save.label, "Save changes")
        XCTAssertFalse(save.isEnabled, "nothing changed yet")
        XCTAssertFalse(app.buttons["record.what.this"].exists, "one schedule: no What")
        XCTAssertFalse(app.buttons["record.before.usual"].exists, "a schedule has its own padding, never Usual")
        attach(app, "record-change")
        let cancel = app.buttons["record.cancelRecording"]
        XCTAssertTrue(cancel.exists)
        XCTAssertTrue(waitUntil { cancel.hasFocus }, "focus starts on Cancel recording (Save is off): \(focused(app).identifier)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { !any["record.page"].exists }, "the page did not close")
        XCTAssertTrue(any["undo.toast"].waitForExistence(timeout: 5), "no Undo")
        attach(app, "record-change-cancelled-undo")
    }

    /// Codex 5a round 1 (medium): the schedule starts recording while Change recording is open. Start early locks (its
    /// edit would be refused), Finish late can still change, and Cancel becomes Stop recording.
    @MainActor
    func testChangeRecordingFollowsItsScheduleWhenItStartsRecording() throws {
        let app = launch("record-change", flip: "recording")
        XCTAssertTrue(app.buttons["record.before.10"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["record.before.10"].isEnabled, "Start early can change before it records")
        XCTAssertTrue(waitUntil(10) { !app.buttons["record.before.10"].isEnabled }, "Start early did not lock once it recorded")
        XCTAssertTrue(app.buttons["record.after.30"].isEnabled, "Finish late can still change")
        XCTAssertTrue(app.buttons["record.cancelRecording"].label.hasPrefix("Stop recording"), app.buttons["record.cancelRecording"].label)
        XCTAssertTrue(app.staticTexts["It is recording: only Finish late can change."].exists)
        attach(app, "record-change-now-recording")
    }

    /// The schedule ends while the page is open: Save changes and Cancel recording are off, and the page says why.
    @MainActor
    func testChangeRecordingSaysSoWhenItsScheduleIsGone() throws {
        let app = launch("record-change", flip: "gone")
        let cancel = app.buttons["record.cancelRecording"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(10) { !cancel.isEnabled }, "Cancel recording stayed on for a schedule that is gone")
        XCTAssertFalse(app.buttons["record.schedule"].isEnabled)
        XCTAssertFalse(app.buttons["record.after.30"].isEnabled, "no change to a schedule that is gone")
        XCTAssertTrue(app.staticTexts["This recording has finished or no longer exists, so it cannot be changed."].exists)
    }
}
#endif
