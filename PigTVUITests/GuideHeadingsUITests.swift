import XCTest

#if os(tvOS)
/// maroge1990/PigTV#372: divider channels are section headings in the TV Guide, and the remote never stops on one. On the
/// offline fixture with headings (PIGTV_UI_TEST_GUIDE_SHAPE=headings, GuideFixtures.withHeadings): rows are
/// SPORTS·, 6 sports channels, MOVIES·, HBO, Sky Cinema Premiere, Film4, TCM (no programmes), NEWS·, BBC News, Sky News,
/// CNN International, KIDS·, JUNIOR·, CBeebies, RADIO· (· a heading: first, beside the no-programme row, two in a row, last).
final class GuideHeadingsUITests: XCTestCase {
    private let headings = ["SPORTS", "MOVIES", "NEWS", "KIDS", "JUNIOR", "RADIO"]
    private let noProgrammes = "No programme information — watch live"

    private func focusedLabel(_ app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        return element.exists ? element.label : "<none>"
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "guide"
        app.launchEnvironment["PIGTV_UI_TEST_GUIDE_SHAPE"] = "headings"
        app.launch()
        XCTAssertTrue(app.collectionViews["guide.grid"].waitForExistence(timeout: 10), "guide grid not shown")
        return app
    }

    /// Presses `button` and answers where focus landed.
    @discardableResult
    private func press(_ app: XCUIApplication, _ button: XCUIRemote.Button, _ times: Int = 1) -> String {
        for _ in 0..<times {
            XCUIRemote.shared.press(button)
            usleep(350_000)
        }
        let label = focusedLabel(app)
        XCTAssertFalse(headings.contains { label.contains($0) }, "focus landed on a heading: \(label)")
        return label
    }

    private func assertOn(_ label: String, _ channel: String, _ what: String, line: UInt = #line) {
        XCTAssertTrue(label.hasPrefix("\(channel), ") || label.hasSuffix(" \(channel)") || label == channel,
                      "\(what): focus on \(label), not \(channel)", line: line)
    }

    @MainActor
    func testUpAndDownPassOverEveryHeading() throws {
        let app = launch()
        // Down from the tab bar into the grid: its first row is a heading, so focus lands on the first channel's row.
        var label = "<none>"
        for _ in 0..<8 where !label.contains(", ") && !label.hasSuffix(" Sky Sports Main Event") { label = press(app, .down) }
        assertOn(label, "Sky Sports Main Event", "into the grid under the first-row heading")
        // Up from the first channel leaves the grid (the heading above it is not a stop), and Down comes back.
        let above = press(app, .up)
        XCTAssertFalse(above.contains("Sky Sports Main Event"), "Up stayed in the grid: \(above)")
        assertOn(press(app, .down), "Sky Sports Main Event", "back down into the grid")
        assertOn(press(app, .down, 5), "beIN Sports 1", "down the sports rows")
        assertOn(press(app, .down), "HBO", "Down over MOVIES")
        assertOn(press(app, .up), "beIN Sports 1", "Up over MOVIES")
        XCTAssertEqual(press(app, .down, 4), noProgrammes, "down to TCM, the row with no programmes")
        assertOn(press(app, .down), "BBC News", "Down over NEWS, beside the no-programme row")
        XCTAssertEqual(press(app, .up), noProgrammes, "Up over NEWS onto the no-programme row")
        assertOn(press(app, .down, 3), "CNN International", "down the news rows")
        assertOn(press(app, .down), "CBeebies", "Down over two headings in a row")
        assertOn(press(app, .down), "CBeebies", "Down at the last channel: the heading under it is not a stop")
        assertOn(press(app, .right), "CBeebies", "Right stays in the row")
        assertOn(press(app, .left), "CBeebies", "Left stays in the row")
        assertOn(press(app, .up), "CNN International", "Up over two headings in a row")
    }
}
#endif
