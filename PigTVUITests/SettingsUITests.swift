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
        XCTAssertTrue(reach(signOut, in: app, from: .right), "focus never moved into the page: \(focused(app).identifier)")
        XCTAssertGreaterThan(signOut.frame.minX, items[1].frame.maxX)
    }

    @MainActor
    func testAFixtureCanOpenAPage() throws {
        let app = launch(page: "appearance")
        XCTAssertTrue(app.buttons["appearance.dark"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.buttons["settings.menu.appearance"].value as? String, "Selected")
    }
}
#endif
