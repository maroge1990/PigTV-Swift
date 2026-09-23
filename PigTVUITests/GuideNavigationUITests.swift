import XCTest

#if os(tvOS)
// Remote navigation across the guide grid, on the offline guide fixture
// (PIGTV_UI_TEST_SCREEN=guide; no server).
final class GuideNavigationUITests: XCTestCase {
    private func focusedLabel(_ app: XCUIApplication) -> String {
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        return focused.exists ? focused.label : "<none>"
    }

    @MainActor
    func testRightNavigationAdvancesThroughTheDay() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "guide"
        app.launch()
        // Reach a programme cell (labels read "<channel>, <title>").
        for _ in 0..<10 where !focusedLabel(app).contains(", ") {
            XCUIRemote.shared.press(.down)
        }
        let start = focusedLabel(app)
        XCTAssertTrue(start.contains(", "), "no grid cell focused: \(start)")
        var labels = [start]
        for step in 0..<12 {
            XCUIRemote.shared.press(.right)
            labels.append(focusedLabel(app))
            if ProcessInfo.processInfo.environment["PIGTV_UI_TEST_STEP_SHOTS"] != nil || step < 4 {
                let frame = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true")).frame
                print("step \(step): \(labels.last!) frame \(frame)")
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "step \(step)"
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
        print("Right-navigation focus sequence: \(labels)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Guide after 12 × Right"
        shot.lifetime = .keepAlways
        add(shot)
        // 12 presses should visit well beyond the first two-hour window.
        XCTAssertGreaterThanOrEqual(Set(labels).count, 8, "focus stalled: \(labels)")
        // Left must come all the way back (through live) to the channel tile.
        var back: [String] = []
        for _ in 0..<16 {
            XCUIRemote.shared.press(.left)
            print("left press \(back.count) sent")
            back.append(focusedLabel(app))
            print("left press \(back.count - 1): \(back.last!)")
            if !back.last!.contains(", ") { break }
        }
        print("Left-navigation focus sequence: \(back)")
        XCTAssertEqual(back.last, "Sky Sports Main Event", "Left did not reach the channel tile: \(back)")
    }
}
#endif
