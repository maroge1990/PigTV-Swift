import XCTest

#if os(tvOS)
// C-I (build 30): the Sport tab on its offline fixture (PIGTV_UI_TEST_SCREEN=
// sport; no server). Down from the tab bar reaches the league chips, then the
// first live card; long press offers the channel picker; Select on an
// upcoming event opens its page. Screenshots are attached for review.
final class SportUITests: XCTestCase {
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
    func testChipsCardsChannelPickerAndEventPage() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "sport"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        XCTAssertTrue(app.buttons["sport.event.nfl-kc-buf"].waitForExistence(timeout: 10), "the Sport tab did not open")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(focused(app).identifier.hasPrefix("sport.league."), "focus after Down: \(focused(app).identifier)")
        XCUIRemote.shared.press(.down)
        XCTAssertEqual(focused(app).identifier, "sport.event.nfl-kc-buf", "Down from the chips lands on the first live card")
        attach(app, "sport-card-focused")

        // Long press: the channel picker.
        XCUIRemote.shared.press(.select, forDuration: 1.5)
        let choose = app.descendants(matching: .any)["Choose a channel"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5), "no long-press menu")
        attach(app, "sport-long-press-menu")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["sport.channel.1:ch3"].waitForExistence(timeout: 5), "the channel picker did not open")
        attach(app, "sport-channel-picker")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["sport.event.nfl-kc-buf"].waitForExistence(timeout: 5))

        // Down to Starting soon, Select: the event page.
        XCUIRemote.shared.press(.down)
        let soon = focused(app).identifier
        XCTAssertEqual(soon, "sport.event.nrl-pf", "Down from On now lands on the first upcoming card")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["sport.watch"].waitForExistence(timeout: 5), "the event page did not open")
        XCTAssertTrue(app.buttons["sport.record"].exists)
        attach(app, "sport-event-page")
    }

    // Build 33 (Mark, live testing): on an upcoming event, choosing a
    // channel other than the recommended one must offer Record/Watch when
    // it starts, not tune at once. Covers both the event page's channel
    // list and the long-press picker (same underlying rule).
    @MainActor
    func testUpcomingEventSecondaryChannelOffersRecordOrWatchInsteadOfTuning() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "sport"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        XCTAssertTrue(app.buttons["sport.event.nfl-kc-buf"].waitForExistence(timeout: 10), "the Sport tab did not open")
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        XCTAssertEqual(focused(app).identifier, "sport.event.nrl-pf", "Down from On now lands on the first upcoming card")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["sport.watch"].waitForExistence(timeout: 5), "the event page did not open")

        // Into the channel list: row 0 is the recommended channel, row 1 the
        // second (non-recommended) one, "TSN 1" in the fixture.
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        XCTAssertEqual(focused(app).identifier, "sport.channel.1:ch1", "the second, non-recommended channel")
        XCUIRemote.shared.press(.select)

        // Each labelled button (icon + text) exposes a nested accessibility
        // element sharing the same label, so match `.firstMatch`.
        let record = app.buttons["Record on TSN 1"].firstMatch
        let watch = app.buttons["Watch TSN 1 when it starts"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5),
                      "an upcoming event's secondary channel must offer Record, not tune immediately")
        XCTAssertTrue(watch.exists)
        attach(app, "sport-channel-choice")

        // Watch when it starts (the dialog's second button): closes the
        // page, no player, a pending-watch banner back on the Sport tab.
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(watch.hasFocus, "expected the dialog's second button to gain focus")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["sport.event.nfl-kc-buf"].waitForExistence(timeout: 5), "the event page did not close")
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5), "the pending-watch banner did not appear")
    }

    // Audit R04/R05: the shelves are lazy now. On a production-sized feed
    // (215 events, 153 of them replays) focus must keep moving along the long
    // Replays shelf, come back to the first card, and return to the same card
    // after an event page is opened and dismissed (the page belongs to the
    // screen, not to a card that may be recycled).
    @MainActor
    func testFocusSurvivesScrollingALongLazyShelfAndAPageRoundTrip() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "sport"
        app.launchEnvironment["PIGTV_UI_TEST_SPORT_EVENTS"] = "215"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        XCTAssertTrue(app.buttons["sport.league.All"].waitForExistence(timeout: 15), "the Sport tab did not open")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(focused(app).identifier.hasPrefix("sport.league."))
        // Down through the shelves to the last one, Replays.
        var presses = 0
        while !focused(app).identifier.hasPrefix("sport.event.rp-") && presses < 20 {
            XCUIRemote.shared.press(.down)
            presses += 1
        }
        let first = focused(app).identifier
        XCTAssertTrue(first.hasPrefix("sport.event.rp-"), "never reached the Replays shelf: \(first)")
        attach(app, "sport-replays-first")

        // Far along the shelf, then back to the start.
        var seen: [String] = [first]
        for _ in 0..<40 {
            XCUIRemote.shared.press(.right)
            let id = focused(app).identifier
            XCTAssertTrue(id.hasPrefix("sport.event.rp-"), "focus left the shelf or was lost: \(id)")
            XCTAssertNotEqual(id, seen.last, "focus stalled at \(id)")
            seen.append(id)
        }
        attach(app, "sport-replays-far")
        let far = try XCTUnwrap(seen.last)
        for _ in 0..<40 { XCUIRemote.shared.press(.left) }
        XCTAssertEqual(focused(app).identifier, first, "back at the first replay")

        // An event page opened from far along the shelf and dismissed leaves
        // focus on that same card. (The fixture's replays are all on now, so
        // Select would play: long press → Event details instead.)
        for _ in 0..<40 { XCUIRemote.shared.press(.right) }
        XCTAssertEqual(focused(app).identifier, far)
        XCUIRemote.shared.press(.select, forDuration: 1.5)
        XCTAssertTrue(app.descendants(matching: .any)["Event details"].waitForExistence(timeout: 5), "no long-press menu")
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["sport.watch"].waitForExistence(timeout: 5), "the event page did not open")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons[far].waitForExistence(timeout: 5))
        XCTAssertEqual(focused(app).identifier, far, "focus returns to the card that opened the page")
    }
}
#endif
