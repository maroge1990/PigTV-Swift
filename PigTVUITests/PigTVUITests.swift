import XCTest

final class PigTVUITests: XCTestCase {
    @MainActor
    func testAppearanceRemainsUsable() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "settings"
        app.launch()
        var previousMode: String?
        for mode in ["light", "dark", "system", "light", "dark"] {
            let button = app.buttons["appearance.\(mode)"]
            XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription)
            #if os(tvOS)
            if let previousMode {
                let order = ["system", "light", "dark"]
                let distance = order.firstIndex(of: mode)! - order.firstIndex(of: previousMode)!
                for _ in 0..<abs(distance) {
                    XCUIRemote.shared.press(distance > 0 ? .down : .up)
                }
            } else {
                // Initial focus may be in the tab bar. Reach the first target;
                // subsequent moves exercise the known adjacent appearance rows.
                for _ in 0..<8 {
                    if button.hasFocus { break }
                    XCUIRemote.shared.press(.down)
                }
                XCTAssertTrue(button.hasFocus, app.debugDescription)
            }
            XCUIRemote.shared.press(.select)
            #else
            button.tap()
            #endif
            previousMode = mode
            print("Appearance after choosing \(mode): \(app.debugDescription)")
            let state = XCTAttachment(screenshot: app.screenshot())
            state.name = "Appearance \(mode)"
            state.lifetime = .keepAlways
            add(state)
            let selected = NSPredicate(format: "value == %@", "Selected")
            expectation(for: selected, evaluatedWith: button)
            waitForExpectations(timeout: 5)
            XCTAssertTrue(app.buttons["appearance.system"].exists)
            XCTAssertTrue(app.buttons["appearance.dark"].exists)
            XCTAssertTrue(app.buttons["appearance.light"].exists)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Settings after repeated appearance changes"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
