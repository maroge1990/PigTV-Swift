import XCTest

#if os(tvOS)
// Build 32: the Top Shelf cards. Opens the topshelf-cards fixture (which
// renders the Home fixture's cards through the real export into the App
// Group and posts topShelfContentDidChange), screenshots it, then goes to
// the Home Screen, focuses PigTV in the top row and screenshots the Top
// Shelf. PIGTV_SCREENSHOT_DIR (passed as TEST_RUNNER_PIGTV_SCREENSHOT_DIR)
// also saves both as PNGs there.
final class TopShelfCardsUITests: XCTestCase {
    @MainActor
    func testCardsRenderAndShowOnTheTopShelf() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "topshelf-cards"
        app.launch()
        let summary = app.staticTexts["topshelf.cards"]
        let rendered = NSPredicate(format: "label CONTAINS %@", "cards rendered")
        expectation(for: rendered, evaluatedWith: summary)
        waitForExpectations(timeout: 60)
        XCTAssertFalse(summary.label.hasPrefix("0 "), summary.label)
        save(XCUIScreen.main.screenshot(), "topshelf-cards-fixture")

        XCUIRemote.shared.press(.home)
        let headBoard = XCUIApplication(bundleIdentifier: "com.apple.HeadBoard")
        let icon = headBoard.icons["PigTV"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 10), headBoard.debugDescription)
        // Walk focus towards PigTV's icon (the top row shows its Top Shelf).
        let focusedIcon = headBoard.icons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        for _ in 0..<24 {
            if icon.hasFocus { break }
            guard focusedIcon.exists else { XCUIRemote.shared.press(.down); continue }
            let from = focusedIcon.frame, to = icon.frame
            if from.midY > to.maxY { XCUIRemote.shared.press(.up) }
            else if from.midY < to.minY { XCUIRemote.shared.press(.down) }
            else { XCUIRemote.shared.press(from.midX < to.midX ? .right : .left) }
        }
        XCTAssertTrue(icon.hasFocus, "PigTV is not in the top row: \(headBoard.debugDescription)")
        Thread.sleep(forTimeInterval: 6)
        save(XCUIScreen.main.screenshot(), "topshelf-home-screen")
    }

    private func save(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["PIGTV_SCREENSHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}
#endif
