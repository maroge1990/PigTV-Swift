import XCTest

#if os(tvOS)
/// #132: while the tuning card covers an installed player (no picture yet), the card owns the remote: its Cancel
/// holds focus, Menu leaves, and nothing reaches the player's hidden actions (favourite, record, chrome).
final class PlayerTuningUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testTheTuningCardOwnsTheRemoteUntilTheFirstPicture() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "player-starting"
        app.launch()
        XCTAssertTrue(app.staticTexts["Tuning…"].waitForExistence(timeout: 10))
        let player = app.descendants(matching: .any)["review.livePlayer"]
        XCTAssertTrue(player.waitForExistence(timeout: 5), "the player is installed under the card")
        let focused = { app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true")) }
        XCTAssertTrue(waitUntil(5) { focused().label == "Cancel" }, "Cancel holds focus, not \(focused().label)")
        for press in [XCUIRemote.Button.right, .right, .down, .left, .up] {
            XCUIRemote.shared.press(press)
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertEqual(focused().label, "Cancel")
        // The chrome hides on its own idle timer; input would move the action cursor, open the channel list or scrub.
        let untouched = { (state: String) in
            !state.hasPrefix("channels") && !state.hasPrefix("scrub") && state.contains("action=0;") && state.contains("channel=2;")
        }
        let state = player.value as? String ?? ""
        XCTAssertTrue(untouched(state), "no input reached the player: \(state)")
        // Menu is the card's (it leaves the player; this fixture is not presented, so it stays): the player's own
        // Menu handler would hide its chrome or end the play.
        XCUIRemote.shared.press(.menu)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(player.exists && app.staticTexts["Tuning…"].exists, "Menu did not reach the player (it would leave)")
        XCTAssertTrue(untouched(player.value as? String ?? ""))
    }
}
#endif
