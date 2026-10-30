import XCTest

#if os(tvOS)
/// #179 (Apple 83): a play from outside the screen (a Top Shelf card, a "watch when it starts" timer) closes the page
/// that is open and the player appears. Before 83, Home's own covers ignored the close signal, so the player could not
/// present over them and the play was given up. Offline Home fixture: Home's hero opens its channel's schedule (one
/// of those covers), then a Top Shelf link arrives (delivered inside the app, as onOpenURL would: a link opened by the
/// test runner starts a second scene of the fixture).
final class OutsidePlayUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testAPlayLinkClosesAnOpenHomePageAndThePlayerAppears() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "home"
        // A play reaches the real player; its resolve goes to a non-routable address, so it stays on the tuning card.
        app.launchEnvironment["PIGTV_UI_TEST_DASHBOARD_PLAY"] = "1"
        // The link arrives 12 s after launch, with the schedule page open (as a Top Shelf card or timer would).
        app.launchEnvironment["PIGTV_UI_TEST_OPEN_URL"] = "12|pigtv://play?sourceId=1&id=ch4&name=Sky%20Sports%20F1"
        app.launch()
        let started = Date()
        let watch = app.buttons["home.watch"]
        XCTAssertTrue(watch.waitForExistence(timeout: 10))
        let focused = { app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true")) }
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitUntil(5) { focused().identifier == "home.watch" }, "focus: \(focused().label)")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitUntil(5) { focused().label == "Schedule" }, "the hero's Schedule button, not \(focused().label)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil(8) { !watch.isHittable }, "the schedule page covers Home")
        XCTAssertLessThan(Date().timeIntervalSince(started), 11, "the page opened before the link arrives")

        // The player screen comes up on its tuning card (the address is unreachable, so it stays there), over Home.
        let tuning = app.staticTexts["Tuning…"]
        XCTAssertTrue(tuning.waitForExistence(timeout: 15), "the player appears in place of the closed page")
        // The watchdog (6 s) does not give the play up: its player did appear.
        Thread.sleep(forTimeInterval: 7)
        XCTAssertTrue(tuning.exists, "the play is still on")
        // Leaving the player lands on Home: the schedule page was closed, not left under the player (Apple 82 left it).
        XCTAssertTrue(waitUntil(5) { focused().label == "Cancel" }, "the tuning card's Cancel, not \(focused().label)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil(8) { !tuning.exists }, "the player closes")
        XCTAssertTrue(waitUntil(8) { watch.isHittable }, "back on Home, not on the schedule page")
    }
}
#endif
