import XCTest

/// #349: one tuning card from the resolve until the first picture. On a slow start (PIGTV_UI_TEST_SCREEN=player-slow-start:
/// the resolve answers after 3 s and no picture follows) the card that showed while resolving is the card that waits for
/// the picture: the same card (its identity, `shownAt`, the probe's value), never rebuilt as a second "Tuning…" screen.
/// On 319 the card was drawn in two places and rebuilt when `ready` flipped.
final class PlayerSlowStartUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func testTheTuningCardKeepsItsIdentityWhenThePlayerIsInstalled() {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "player-slow-start"
        app.launch()
        let card = app.descendants(matching: .any)["tuning.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the tuning card while resolving")
        let first = card.value as? String
        XCTAssertNotNil(first)
        attach(app, "slow-start-1-resolving")
        let closes = app.buttons.matching(identifier: "Close player")
        XCTAssertEqual(closes.count, 1, "one Close button")
        // The resolve answers at 3 s: the player is installed under the card.
        Thread.sleep(forTimeInterval: 4.5)
        #if os(tvOS)
        XCTAssertTrue(app.descendants(matching: .any)["review.livePlayer"].exists, "the player is installed under the card")
        #endif
        XCTAssertTrue(card.exists, "still the tuning card (no picture)")
        XCTAssertEqual(card.value as? String, first, "the same card, not a second one built when the player was installed")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "tuning.card").count, 1, "one card")
        XCTAssertEqual(closes.count, 1, "one Close button")
        #if os(tvOS)
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        XCTAssertEqual(focused.label, "Close player", "the card's Close keeps focus")
        #endif
        attach(app, "slow-start-2-installed")
    }
}
