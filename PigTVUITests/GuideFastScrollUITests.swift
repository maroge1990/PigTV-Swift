import XCTest

#if os(tvOS)
// 18 Oct (app test team): fast scrolling the tvOS guide down (or up) moved the list, but when it stopped focus pulled
// back to the row it started from. On the offline guide fixture enlarged to 300 channels: hold Down, let go, and focus
// must settle well down the list, in the row on screen, not back at the top; then the same upwards.
final class GuideFastScrollUITests: XCTestCase {
    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    /// The focused cell's channel: programme cells read "<channel>, <title>…", tiles the channel alone.
    private func focusedChannel(_ app: XCUIApplication) -> String {
        let element = focused(app)
        guard element.exists else { return "<none>" }
        return String(element.label.split(separator: ",").first ?? "")
    }

    @MainActor
    func testFocusFollowsAFastScrollInsteadOfSnappingBack() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "guide"
        app.launchEnvironment["PIGTV_UI_TEST_CHANNELS"] = "300"
        app.launch()
        let grid = app.collectionViews["guide.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 15), "guide grid not shown")
        for _ in 0..<8 where !grid.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists {
            XCUIRemote.shared.press(.down)
        }
        let top = focused(app).frame
        let start = focusedChannel(app)
        XCTAssertNotEqual(start, "<none>", "no grid cell focused")

        /// Settled: the same focused cell on two reads 0.5 s apart.
        func settle() -> CGRect {
            var last = focused(app).frame
            _ = waitUntil(8) {
                Thread.sleep(forTimeInterval: 0.5)
                let now = focused(app).frame
                defer { last = now }
                return now == last
            }
            return last
        }

        XCUIRemote.shared.press(.down, forDuration: 4)
        let down = settle()
        let afterDown = focusedChannel(app)
        print("FASTSCROLL start \(start) \(top) → down \(afterDown) \(down) offset \(grid.cells.firstMatch.frame)")
        XCTAssertNotEqual(afterDown, start, "after a fast scroll down focus went back to \(start)")
        XCTAssertTrue(down.minY >= grid.frame.minY - 1 && down.maxY <= grid.frame.maxY + 1,
                      "the focused cell \(down) is not on screen in the grid \(grid.frame)")

        XCUIRemote.shared.press(.up, forDuration: 2)
        let up = settle()
        let afterUp = focusedChannel(app)
        print("FASTSCROLL up → \(afterUp) \(up)")
        XCTAssertNotEqual(afterUp, afterDown, "after a fast scroll up focus went back to \(afterDown)")
        XCTAssertTrue(up.minY >= grid.frame.minY - 1 && up.maxY <= grid.frame.maxY + 1,
                      "the focused cell \(up) is not on screen in the grid \(grid.frame)")
    }
}
#endif
