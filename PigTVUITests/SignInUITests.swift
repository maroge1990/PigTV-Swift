import XCTest

#if os(tvOS)
/// D-44 batch 6 (R5-SignIn-TV): Sign in is the server first, then two big tiles, Pair with browser and Username and
/// password (PIGTV_UI_TEST_SCREEN=onboarding has a saved server; signin-server asks for one).
final class SignInUITests: XCTestCase {
    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = screen
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        return app
    }

    private func reach(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<10 where !target.hasFocus {
            let at = focused(app).frame, to = target.frame
            XCUIRemote.shared.press(abs(at.midY - to.midY) > max(25, to.height / 2) ? (at.midY < to.midY ? .down : .up)
                                    : (at.midX < to.midX ? .right : .left))
            _ = waitUntil(1) { target.hasFocus }
        }
        return waitUntil(5) { target.hasFocus }
    }

    @MainActor
    func testWithAKnownServerSignInOffersTheTwoTilesAndChangeGoesBackToTheServer() throws {
        continueAfterFailure = false
        let app = launch("onboarding")
        let pair = app.buttons["signin.pair"], password = app.buttons["signin.password"]
        XCTAssertTrue(pair.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(password.exists)
        XCTAssertEqual(pair.frame.midY, password.frame.midY, accuracy: 20, "the two tiles sit side by side (the focused one is lifted)")
        XCTAssertLessThan(pair.frame.maxX, password.frame.minX, "Pair with browser first")
        XCTAssertFalse(app.textFields["signin.address"].exists, "the server is step 1, already done")
        XCTAssertTrue(waitUntil(5) { pair.hasFocus }, "the recommended tile takes the focus: \(focused(app).identifier)")
        // Username and password opens the two fields; Menu goes back to the tiles.
        XCTAssertTrue(reach(password, in: app))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.textFields["signin.username"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["signin.passwordField"].exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(password.waitForExistence(timeout: 5), "Menu should go back to the tiles")
        // Change returns to step 1.
        let change = app.buttons["signin.server.change"]
        XCTAssertTrue(reach(change, in: app), "Change never took the focus: \(focused(app).identifier)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.textFields["signin.address"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["signin.continue"].exists)
        XCTAssertFalse(pair.exists)
    }

    @MainActor
    func testADifferentServerStartsAtTheServer() throws {
        let app = launch("signin-server")
        XCTAssertTrue(app.textFields["signin.address"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["signin.continue"].exists)
        XCTAssertFalse(app.buttons["signin.pair"].exists)
    }
}
#endif
