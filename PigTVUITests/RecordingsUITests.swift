import XCTest

#if os(tvOS)
// The Recordings poster grid on the offline fixture
// (PIGTV_UI_TEST_SCREEN=tab-recordings): the needs-attention banner, the
// Continue watching row and the All recordings grid are reachable with the remote.
final class RecordingsUITests: XCTestCase {
    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testPosterGridIsReachableWithTheRemote() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "tab-recordings"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'The Headlines'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "no recording tile")
        attach(app, "recordings-initial")
        var seen = Set<String>()
        for _ in 0..<8 {
            XCUIRemote.shared.press(.down)
            seen.insert(focused(app).label)
        }
        attach(app, "recordings-after-down")
        XCTAssertTrue(seen.contains { $0.hasPrefix("The Headlines") || $0.hasPrefix("Grand Final") || $0.hasPrefix("Feature Film") },
                      "focus never reached a recording tile: \(seen)")
        XCUIRemote.shared.press(.right)
        XCTAssertFalse(focused(app).label.isEmpty)
    }

    @MainActor
    func testReviewSheetIsFocusableAndOffersDelete() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "tab-recordings"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        let banner = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Review'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "no needs-attention banner")
        var reached = false
        for _ in 0..<10 {
            if focused(app).label.contains("Review") { reached = true; break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(reached, "focus never reached the banner: \(focused(app).label)")
        XCUIRemote.shared.press(.select)
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the Review list has no Delete")
        attach(app, "recordings-review")
        XCTAssertTrue(focused(app).label.contains("Delete") || focused(app).exists, "nothing focused in the Review list")
    }
}
#endif
