import XCTest

#if os(tvOS)
/// D-44 batch 6 (R5-Settings-TV): Settings is a menu beside its page. Signed in on the offline fixture
/// (PIGTV_UI_TEST_SCREEN=settings-sport), the menu lists Sport, Account, Appearance, Labs, Diagnostics and About, the page
/// beside it follows the focused item, and the remote moves from the menu into the page.
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

    @MainActor
    func testTheMenuSitsBesideItsPageAndThePageFollowsTheFocus() throws {
        continueAfterFailure = false
        let app = launch()
        let ids = ["sport", "account", "appearance", "labs", "diagnostics", "about"].map { "settings.menu.\($0)" }
        let items = ids.map { app.buttons[$0] }
        XCTAssertTrue(items[0].waitForExistence(timeout: 10), app.debugDescription)
        for item in items { XCTAssertTrue(item.exists, "missing \(item)") }
        let tops = items.map(\.frame.minY)
        XCTAssertEqual(tops, tops.sorted(), "the menu reads Sport, Account, Appearance, Labs, Diagnostics, About")
        // The Sport page opens beside the menu.
        let football = app.buttons["settings.sport.row.Football"]
        XCTAssertTrue(football.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(football.frame.minX, items[0].frame.maxX, "the page is beside the menu, not below it")
        // Into the menu (Down from the tab bar may land in the page; Left from the page enters the menu), then down to
        // Account: its page replaces Sport's.
        for _ in 0..<8 where !focused(app).identifier.hasPrefix("settings.menu.") {
            XCUIRemote.shared.press(focused(app).identifier.hasPrefix("settings.") ? .left : .down)
            _ = waitUntil(1) { focused(app).identifier.hasPrefix("settings.menu.") }
        }
        XCTAssertTrue(reach(items[1], in: app), "focus never reached Account: \(focused(app).identifier)")
        let signOut = app.buttons["settings.account.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5), "Account's page did not open")
        XCTAssertFalse(football.exists)
        // Right moves into the page.
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitUntil(5) { focused(app).identifier.hasPrefix("settings.account.") },
                      "focus never moved into the page: \(focused(app).identifier)")
        XCTAssertGreaterThan(focused(app).frame.minX, items[1].frame.maxX)
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
