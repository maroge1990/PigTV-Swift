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
}
#endif
