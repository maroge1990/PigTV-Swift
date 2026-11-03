import XCTest

#if os(tvOS)
// The Recordings tab on the offline fixture (PIGTV_UI_TEST_SCREEN=tab-recordings): D-44 (Apple 119) the featured
// recording, the cards and the Coming up strip are reachable with the remote, and "All ›" opens Scheduled.
final class RecordingsUITests: XCTestCase {
    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testPosterGridIsReachableWithTheRemote() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "tab-recordings"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        // Apple 119: The Headlines (partly watched) is the featured recording; the rest are cards.
        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Grand Final'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "no recording tile")
        attach(app, "recordings-initial")
        var seen = Set<String>()
        for _ in 0..<8 {
            XCUIRemote.shared.press(.down)
            seen.insert(focused(app).label)
        }
        attach(app, "recordings-after-down")
        XCTAssertTrue(seen.contains { $0.hasPrefix("Grand Final") || $0.hasPrefix("Feature Film") || $0.hasPrefix("AFL: Collingwood") },
                      "focus never reached a recording tile: \(seen)")
        XCUIRemote.shared.press(.right)
        XCTAssertFalse(focused(app).label.isEmpty)
    }

    /// D-44 (Apple 119): no library. The featured recording (Continue: The Headlines), the cards, and Coming up, whose
    /// "All ›" opens Scheduled.
    @MainActor
    func testFeaturedRecordingCardsAndComingUpOpenScheduled() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "tab-recordings"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        let any = app.descendants(matching: .any)
        let featured = any["recordings.featured"]
        XCTAssertTrue(featured.waitForExistence(timeout: 10), "no featured recording")
        XCTAssertTrue(featured.label.hasPrefix("The Headlines"), featured.label)
        XCTAssertTrue(app.buttons["recordings.featured.play"].exists, "the featured recording offers Resume")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Late Movie'")).firstMatch.exists,
                       "a failed recording is not on the tab (Scheduled › Needs attention has it)")
        let all = app.buttons["recordings.comingUp.all"]
        XCTAssertTrue(all.exists, "Coming up has All ›")
        for _ in 0..<6 where !focused(app).identifier.hasPrefix("recordings.comingUp") { XCUIRemote.shared.press(.down) }
        for _ in 0..<6 where focused(app).identifier != "recordings.comingUp.all" { XCUIRemote.shared.press(.right) }
        attach(app, "recordings-tab")
        XCTAssertEqual(focused(app).identifier, "recordings.comingUp.all", "focus never reached All ›")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Cancel schedule"].waitForExistence(timeout: 5) || any["scheduled.page"].waitForExistence(timeout: 1),
                      "All › did not open Scheduled")
        attach(app, "recordings-scheduled")
    }

    /// D-44 (Apple 120, R5-Scheduled): Scheduled lists the rules (on/off and Remove) and what needs attention (each with
    /// Delete) beside Coming up, where a schedule names the rule that made it.
    @MainActor
    func testScheduledListsRulesAndNeedsAttentionBesideComingUp() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "tab-recordings"
        app.launchEnvironment["PIGTV_UI_TEST_RECORDINGS_SECTION"] = "scheduled"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        let any = app.descendants(matching: .any)
        let cancel = app.buttons["scheduled.cancel.90"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Coming up has the schedule with its Cancel")
        XCTAssertTrue(any["Series"].exists, "the schedule names the rule that made it")
        XCTAssertTrue(app.buttons["rules.remove.7"].exists, "each rule has Remove")
        XCTAssertTrue(app.buttons["rules.remove.9"].exists)
        XCTAssertTrue(any["rules.toggle.8"].exists, "each rule has its switch")
        let delete = app.buttons["scheduled.delete.schedule-91"]
        XCTAssertTrue(delete.exists, "Needs attention offers Delete on the failed schedule")
        XCTAssertTrue(app.buttons["scheduled.delete.recording-25"].exists, "and on the failed recording")
        var reached = false
        for _ in 0..<12 {
            if focused(app).identifier.hasPrefix("scheduled.delete") { reached = true; break }
            XCUIRemote.shared.press(focused(app).identifier.hasPrefix("scheduled.cancel") ? .right : .down)
        }
        attach(app, "scheduled-page")
        XCTAssertTrue(reached, "focus never reached a Delete in Needs attention: \(focused(app).identifier)")
    }

    /// D-44 (Apple 121, R5-View): a card opens View recording on the tab's own stack: the art, its state, the facts and
    /// its actions; Menu goes back to the tab.
    @MainActor
    func testACardOpensViewRecordingAndMenuGoesBack() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "tab-recordings"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'AFL: Collingwood'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no game card")
        for _ in 0..<12 where !card.hasFocus {
            let at = focused(app).frame, to = card.frame
            XCUIRemote.shared.press(abs(at.midY - to.midY) > 40 ? .down : (at.midX < to.midX ? .right : .left))
            for _ in 0..<10 where !card.hasFocus { Thread.sleep(forTimeInterval: 0.1) }
        }
        XCTAssertTrue(card.hasFocus, "focus never reached the game card")
        XCUIRemote.shared.press(.select)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["recording.facts"].waitForExistence(timeout: 5), "View recording did not open")
        XCTAssertEqual(any["recording.state"].label, "Recorded")
        XCTAssertTrue(app.buttons["recording.play"].exists && app.buttons["recording.findBreaks"].exists
                      && app.buttons["recording.delete"].exists, "Play, Find breaks and Delete")
        attach(app, "recording-view")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(any["recordings.featured"].waitForExistence(timeout: 5), "Menu did not go back to the tab")
    }

    /// #12 (D-42, server 0410; maroge1990/PigTV#200): a schedule that loses its clash says why it waits and offers
    /// "Record this one instead", which asks first (PIGTV_UI_TEST_CLASH=1: 92 wins, 93 loses).
    @MainActor
    func testALosingScheduleOffersRecordThisOneInstead() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "tab-recordings"
        app.launchEnvironment["PIGTV_UI_TEST_RECORDINGS_SECTION"] = "scheduled"
        app.launchEnvironment["PIGTV_UI_TEST_CLASH"] = "1"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        let any = app.descendants(matching: .any)
        let beaten = any["recordings.beaten.93"]
        XCTAssertTrue(beaten.waitForExistence(timeout: 10), "the losing schedule says why it waits")
        XCTAssertEqual(beaten.label, "Clashes with \u{201C}Evening Match\u{201D}, which was scheduled first.")
        XCTAssertFalse(any["recordings.beaten.92"].exists, "the winner is not beaten")
        XCTAssertTrue(any["recordings.clash.92"].label.contains("this one records; Late Movie waits"), any["recordings.clash.92"].label)
        let choose = app.buttons["recordings.choose.93"]
        XCTAssertTrue(choose.exists, "Record this one instead")
        XCTAssertFalse(app.buttons["recordings.choose.92"].exists)
        var reached = false
        for _ in 0..<12 {
            if focused(app).identifier == "recordings.choose.93" { reached = true; break }
            XCUIRemote.shared.press(.down)
        }
        attach(app, "recordings-clash")
        XCTAssertTrue(reached, "focus never reached Record this one instead: \(focused(app).identifier)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Record this one"].waitForExistence(timeout: 5), "the choice is confirmed first")
        // tvOS: the dialog's title is the alert's own label, not a static text.
        XCTAssertTrue(app.alerts["Record Late Movie instead?"].exists || any["Record Late Movie instead?"].exists)
        attach(app, "recordings-clash-confirm")
    }
}
#endif
