import XCTest

#if os(tvOS)
// Build 28: the app opens on Home. On the offline Home fixture
// (PIGTV_UI_TEST_SCREEN=home; no server), Down from the tab bar lands on the
// hero's Watch button and Down again on the first Recently watched card.
final class HomeUITests: XCTestCase {
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
    func testHomeOpensFirstAndTheHeroWatchIsOneStepDown() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "home"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        XCTAssertTrue(app.buttons["home.watch"].waitForExistence(timeout: 10), "Home is not the first tab")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(focused(app).identifier == "home.watch" || focused(app).label.hasPrefix("Watch"),
                      "focus after Down: \(focused(app).label)")
        attach(app, "home-watch-focused")
        XCUIRemote.shared.press(.down)
        let card = focused(app).label
        XCTAssertFalse(card.isEmpty)
        XCTAssertFalse(card.hasPrefix("Watch"), "focus did not move to the shelves: \(card)")
        attach(app, "home-card-focused")
    }
}
#endif
