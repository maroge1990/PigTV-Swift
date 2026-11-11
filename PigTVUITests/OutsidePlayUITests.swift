import XCTest

#if os(tvOS)
/// #179 (Apple 83): a play from outside the screen (a Top Shelf card, a "watch when it starts" timer) closes the page
/// that is open and the player appears. Before 83, Home's own covers ignored the close signal, so the player could not
/// present over them and the play was given up. #216 (Apple 102) retired Home: on the offline library fixture opened on
/// the TV Guide, a programme's details page (one of the Guide's covers) is opened, then a Top Shelf link arrives
/// (delivered inside the app, as onOpenURL would: a link opened by the test runner starts a second scene of the fixture).
final class OutsidePlayUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testAPlayLinkClosesAnOpenGuidePageAndThePlayerAppears() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "tab-guide"
        // A play reaches the real player; its resolve goes to a non-routable address, so it stays on the tuning card.
        app.launchEnvironment["PIGTV_UI_TEST_DASHBOARD_PLAY"] = "1"
        // The link arrives 15 s after launch, with the details page open (as a Top Shelf card or timer would).
        app.launchEnvironment["PIGTV_UI_TEST_OPEN_URL"] = "15|pigtv://play?sourceId=1&id=ch4&name=Sky%20Sports%20F1"
        app.launch()
        let started = Date()
        let grid = app.collectionViews["guide.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        let focused = { app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true")) }
        // Down from the tab bar into the grid, onto a programme ("<channel>, <programme>…").
        for _ in 0..<8 where !focused().label.contains(", ") { XCUIRemote.shared.press(.down) }
        if !focused().label.contains(", ") { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(waitUntil(5) { focused().label.contains(", ") }, "a programme, not \(focused().label)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil(8) { !grid.isHittable }, "the details page covers the guide")
        XCTAssertLessThan(Date().timeIntervalSince(started), 14, "the page opened before the link arrives")

        // The player screen comes up on its tuning card (the address is unreachable, so it stays there).
        let tuning = app.staticTexts["Tuning…"]
        XCTAssertTrue(tuning.waitForExistence(timeout: 15), "the player appears in place of the closed page")
        // The watchdog (6 s) does not give the play up: its player did appear.
        Thread.sleep(forTimeInterval: 7)
        XCTAssertTrue(tuning.exists, "the play is still on")
        // Leaving the player lands on the guide: the details page was closed, not left under the player (Apple 82 left it).
        XCTAssertTrue(waitUntil(5) { focused().label == "Close player" }, "the tuning card's Close player, not \(focused().label)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil(8) { !tuning.exists }, "the player closes")
        XCTAssertTrue(waitUntil(8) { grid.isHittable }, "back on the guide, not on the details page")
    }
}
#endif
