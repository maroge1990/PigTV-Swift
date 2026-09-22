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
        for _ in 0..<12 {
            XCUIRemote.shared.press(.right)
            labels.append(focusedLabel(app))
        }
        print("Right-navigation focus sequence: \(labels)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Guide after 12 × Right"
        shot.lifetime = .keepAlways
        add(shot)
        // 12 presses should visit well beyond the first two-hour window.
        XCTAssertGreaterThanOrEqual(Set(labels).count, 8, "focus stalled: \(labels)")
    }
}
#endif
