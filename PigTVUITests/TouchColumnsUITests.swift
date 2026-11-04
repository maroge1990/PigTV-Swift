import XCTest

#if os(iOS)
/// Edges and top lines on iPhone and iPad (Mark's test of Apple 143, 4 Nov 2026), on the offline fixtures. Run on an
/// iPhone and an iPad simulator; each test skips on the other.
final class TouchColumnsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["PIGTV_SCREENSHOT_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func launch(_ screen: String, idiom: UIUserInterfaceIdiom) throws -> XCUIApplication {
        guard UIDevice.current.userInterfaceIdiom == idiom else { throw XCTSkip("\(idiom == .pad ? "iPad" : "iPhone") only") }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = screen
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        return app
    }

    /// #229: the recording card and the Coming up card are one width, at the header's 16 pt edge. Before Apple 149 the
    /// recording card sat 28 pt in and Coming up 12 pt, and the recordings swapped in with no transition.
    @MainActor
    func testTheRecordingCardAndComingUpShareOneWidth() throws {
        let app = try launch("tab-recordings", idiom: .phone)
        let any = app.descendants(matching: .any)
        let card = any["recordings.stack.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "a recording card")
        let coming = any["recordings.comingUp.card"].firstMatch
        XCTAssertTrue(coming.waitForExistence(timeout: 5), "Coming up")
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(card.frame.minX, coming.frame.minX, accuracy: 1, "\(card.frame) and \(coming.frame)")
        XCTAssertEqual(card.frame.maxX, coming.frame.maxX, accuracy: 1, "\(card.frame) and \(coming.frame)")
        XCTAssertEqual(card.frame.minX - window.minX, 16, accuracy: 1, "the header's edge")
        shot(app, "229-iphone-recordings")
    }

    /// #227: iPad Settings' menu and its page start on one line: the page's first row's text level with the menu's first
    /// row's text. Before Apple 148 the page drew a title on the menu's line and its first card began about 60 pt lower.
    @MainActor
    func testIPadSettingsColumnsShareATopLine() throws {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            let app = try launch("settings-sport", idiom: .pad)
            XCUIDevice.shared.orientation = orientation
            let first = app.buttons["settings.menu.sport"]
            XCTAssertTrue(first.waitForExistence(timeout: 15), "the menu")
            first.tap()
            let menuText = app.staticTexts.matching(NSPredicate(format: "label == 'Sport' AND identifier == ''")).firstMatch
            let pageText = app.staticTexts["Hide scores"].firstMatch
            XCTAssertTrue(pageText.waitForExistence(timeout: 5), "the page's first row")
            Thread.sleep(forTimeInterval: 1)
            let name = orientation == .portrait ? "portrait" : "landscape"
            print(String(format: "SETTINGS %@ menu %.1f page %.1f", name, menuText.frame.minY, pageText.frame.minY))
            XCTAssertEqual(pageText.frame.minY, menuText.frame.minY, accuracy: 2, "menu \(menuText.frame), page \(pageText.frame)")
            shot(app, "227-ipad-settings-\(name)")
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }
}
#endif
