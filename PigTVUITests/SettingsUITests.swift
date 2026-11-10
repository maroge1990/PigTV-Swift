import XCTest

#if os(tvOS)
/// D-44 batch 6 (R5-Settings-TV): Settings is a menu beside its page. Signed in on the offline fixture
/// (PIGTV_UI_TEST_SCREEN=settings-sport), the menu lists Sport, Account, Appearance, Labs, Diagnostics and About; on the
/// Apple TV a summary follows the focused item and a press opens its page (#279).
final class SettingsUITests: XCTestCase {
    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    private func launch(page: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "settings-sport"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        if let page { app.launchEnvironment["PIGTV_UI_TEST_SETTINGS_PAGE"] = page }
        app.launch()
        return app
    }

    /// Presses Down (then Right, into the page) until `target` has the focus.
    private func reach(_ target: XCUIElement, in app: XCUIApplication, from direction: XCUIRemote.Button = .down) -> Bool {
        for _ in 0..<14 {
            if target.hasFocus { return true }
            XCUIRemote.shared.press(direction)
            _ = waitUntil(1) { target.hasFocus }
        }
        return target.hasFocus
    }

    /// Into the menu: Down from the tab bar, Left from the page.
    private func intoTheMenu(_ app: XCUIApplication) {
        for _ in 0..<8 where !focused(app).identifier.hasPrefix("settings.menu.") {
            XCUIRemote.shared.press(focused(app).identifier.hasPrefix("settings.") ? .left : .down)
            _ = waitUntil(1) { focused(app).identifier.hasPrefix("settings.menu.") }
        }
    }

    /// #279 (owner, 11 Nov 2026; Apple 201): a short read-only summary of the section follows focus, the real page opens on a
    /// press and focus moves into it, and Menu returns to the row it came from. Before 201 the page followed the focus.
    @MainActor
    func testTheSummaryFollowsTheFocusAndAPressOpensThePage() throws {
        continueAfterFailure = false
        let app = launch(page: "sport")
        let ids = ["sport", "account", "appearance", "labs", "diagnostics", "about"].map { "settings.menu.\($0)" }
        let items = ids.map { app.buttons[$0] }
        XCTAssertTrue(items[0].waitForExistence(timeout: 10), app.debugDescription)
        for item in items { XCTAssertTrue(item.exists, "missing \(item)") }
        let tops = items.map(\.frame.minY)
        XCTAssertEqual(tops, tops.sorted(), "the menu reads Sport, Account, Appearance, Labs, Diagnostics, About")
        // The fixture opened Sport: its page is beside the menu.
        let football = app.buttons["settings.sport.row.Football"]
        XCTAssertTrue(football.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(football.frame.minX, items[0].frame.maxX, "the page is beside the menu, not below it")
        intoTheMenu(app)
        XCTAssertTrue(reach(items[0], in: app, from: .up), "focus never reached Sport: \(focused(app).identifier)")
        // Down two rows: the summary follows, no page opens and Sport stays the selected row.
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitUntil(3) { items[1].hasFocus })
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitUntil(3) { items[2].hasFocus }, "focus: \(focused(app).identifier)")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.buttons["appearance.dark"].exists, "focus opened Appearance's page")
        XCTAssertFalse(app.buttons["settings.account.signOut"].exists, "focus opened Account's page on the way")
        XCTAssertEqual(items[0].value as? String, "Selected", "moving focus never selects")
        XCTAssertEqual(items[2].value as? String, "")
        let summary = app.descendants(matching: .any)["settings.summary.appearance"]
        XCTAssertTrue(summary.waitForExistence(timeout: 3), "no Appearance summary: \(app.debugDescription)")
        // A press opens the page and focus lands inside it.
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["appearance.dark"].waitForExistence(timeout: 5), "the press did not open Appearance")
        XCTAssertTrue(waitUntil(5) { focused(app).identifier.hasPrefix("appearance.") },
                      "focus did not move into the page: \(focused(app).identifier)")
        XCTAssertGreaterThan(focused(app).frame.minX, items[2].frame.maxX)
        XCTAssertEqual(items[2].value as? String, "Selected")
        // Menu: back to the same row, and its summary again.
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil(5) { items[2].hasFocus }, "Menu did not return to Appearance: \(focused(app).identifier)")
        XCTAssertTrue(summary.waitForExistence(timeout: 3), "no summary after Menu")
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists, "Menu left Settings")
    }

    /// #279: an information page (About in the tab) opens on a press and focus stays on its row.
    @MainActor
    func testAnInformationPageOpensAndFocusStaysOnTheMenu() throws {
        continueAfterFailure = false
        let app = launch()
        let about = app.buttons["settings.menu.about"]
        XCTAssertTrue(about.waitForExistence(timeout: 10), app.debugDescription)
        intoTheMenu(app)
        XCTAssertTrue(reach(about, in: app), "focus never reached About: \(focused(app).identifier)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["settings.page"].waitForExistence(timeout: 5), "About did not open")
        XCTAssertTrue(about.hasFocus, "focus left the menu: \(focused(app).identifier)")
        XCTAssertEqual(about.value as? String, "Selected")
    }

    /// D-44: Sign out is the one action that confirms, and it confirms inside its own row, never in a dialog.
    @MainActor
    func testSignOutConfirmsInsideItsRow() throws {
        continueAfterFailure = false
        let app = launch(page: "account")
        let signOut = app.buttons["settings.account.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<10 where !signOut.hasFocus {
            let at = focused(app).frame
            XCUIRemote.shared.press(at.midY < signOut.frame.minY ? .down : at.midX < signOut.frame.minX ? .right : .up)
            _ = waitUntil(1) { signOut.hasFocus }
        }
        XCTAssertTrue(signOut.hasFocus, "Sign out never took the focus: \(focused(app).identifier)")
        XCUIRemote.shared.press(.select)
        let confirm = app.descendants(matching: .any)["settings.account.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no confirmation in the row: \(app.debugDescription)")
        XCTAssertEqual(app.alerts.count, 0, "a dialog asked instead")
        XCTAssertEqual(app.sheets.count, 0, "a dialog asked instead")
        let stay = app.buttons["settings.account.stay"]
        XCTAssertTrue(waitUntil(5) { stay.hasFocus }, "Stay signed in should take the focus: \(focused(app).identifier)")
        XCTAssertTrue(app.buttons["settings.account.confirmSignOut"].exists)
        // Stay signed in puts the row back.
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil(5) { !confirm.exists }, "Stay signed in left the confirmation open")
        XCTAssertTrue(waitUntil(5) { signOut.hasFocus }, "focus should return to Sign out: \(focused(app).identifier)")
        // Menu answers Stay signed in too.
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil(5) { !confirm.exists }, "Menu left the confirmation open")
        XCTAssertTrue(app.tabBars.buttons["Sport"].exists, "still signed in")
        // Sign out, confirmed in the row, signs out.
        XCTAssertTrue(waitUntil(5) { signOut.hasFocus } || { XCUIRemote.shared.press(.down); return waitUntil(2) { signOut.hasFocus } }())
        XCUIRemote.shared.press(.select)
        let yes = app.buttons["settings.account.confirmSignOut"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitUntil(5) { yes.hasFocus }, "Sign out sits beside Stay signed in: \(focused(app).identifier)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil(5) { !app.tabBars.buttons["Sport"].exists }, "signing out left the session's tabs")
    }

    /// R5-SetSport-TV: Hide scores and Score delay side by side, then your sports with their followed names.
    @MainActor
    func testTheSportPageHasScoreDelayAndYourSports() throws {
        continueAfterFailure = false
        let app = launch(page: "sport")
        let value = app.staticTexts["settings.sport.delay.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(value.label, "Score delay 30 seconds")
        let hide = app.buttons["settings.sport.spoilerFree"]
        XCTAssertLessThan(hide.frame.maxX, value.frame.minX, "Hide scores and Score delay sit side by side")
        let football = app.buttons["settings.sport.row.Football"]
        XCTAssertTrue(football.label.contains("Arsenal, Liverpool"), football.label)
        XCTAssertGreaterThan(football.frame.minY, hide.frame.maxY)
        let more = app.buttons["settings.sport.delay.more"]
        for _ in 0..<12 where !more.hasFocus {
            let at = focused(app).frame
            XCUIRemote.shared.press(at.maxY < more.frame.minY ? .down : at.minY > more.frame.maxY ? .up : at.midX < more.frame.midX ? .right : .left)
            _ = waitUntil(1) { more.hasFocus }
        }
        XCTAssertTrue(waitUntil(5) { more.hasFocus }, "+10 never took the focus: \(focused(app).identifier)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil(5) { value.label == "Score delay 40 seconds" }, value.label)
    }

    @MainActor
    func testAFixtureCanOpenAPage() throws {
        let app = launch(page: "appearance")
        XCTAssertTrue(app.buttons["appearance.dark"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.buttons["settings.menu.appearance"].value as? String, "Selected")
    }
}
#endif
