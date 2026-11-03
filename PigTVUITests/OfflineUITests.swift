import XCTest

#if os(tvOS)
/// D-44 batch 6 (R5-Offline-TV): offline, the pig sits in a ring counting down to the next retry, with Try now (focused)
/// and Use a different server, which opens Sign in at the server (PIGTV_UI_TEST_SCREEN=unreachable).
final class OfflineUITests: XCTestCase {
    private func seconds(_ element: XCUIElement) -> Int? {
        element.label.split(separator: " ").compactMap { Int($0) }.first
    }

    @MainActor
    func testTheRingCountsDownAndADifferentServerOpensSignInAtTheServer() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "unreachable"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        let countdown = app.staticTexts["offline.countdown"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(countdown.label.hasPrefix("Trying again in "), countdown.label)
        let first = try XCTUnwrap(seconds(countdown))
        XCTAssertTrue(waitUntil(6) { (self.seconds(countdown) ?? first) < first }, "the countdown never moved: \(countdown.label)")
        let tryNow = app.buttons["offline.tryNow"]
        XCTAssertTrue(waitUntil(5) { tryNow.hasFocus }, "Try now should take the focus")
        let other = app.buttons["offline.otherServer"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitUntil(5) { other.hasFocus })
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.textFields["signin.address"].waitForExistence(timeout: 5), "Sign in should open at the server")
    }
}
#endif
