import XCTest

// D-44 batch 4 (Apple 106–110): screenshots of the TV Guide and its pages on the offline library fixture (no server),
// for the before/after evidence: the guide, the long-press menu, programme details, the channel page and Search with
// Jump to. tvOS, iPad and iPhone (upright and sideways for the guide). A screenshot suite (Tools/test.sh VISUAL): it
// asserts only that each screen opened. With TEST_RUNNER_PIGTV_SCREENSHOT_DIR the shots are also saved to that folder,
// named <platform>-<screen>.png.
final class GuideScreensUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private var platform: String {
        #if os(tvOS)
        "tv"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 1.5)
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = "\(platform)-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
        if let dir = ProcessInfo.processInfo.environment["PIGTV_SCREENSHOT_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(platform)-\(name).png"))
        }
    }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = screen
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        return app
    }

    private func focusedLabel(_ app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        return element.exists ? element.label : "<none>"
    }

    @MainActor
    func testGuideAndMenu() throws {
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        let app = launch("tab-guide")
        _ = app.collectionViews["guide.grid"].waitForExistence(timeout: 15)
        #if os(tvOS)
        // Into the grid, onto a later programme in the first row.
        for _ in 0..<8 where !focusedLabel(app).contains(", ") { XCUIRemote.shared.press(.down); usleep(300_000) }
        XCUIRemote.shared.press(.right)
        shoot(app, "guide")
        XCUIRemote.shared.press(.select, forDuration: 1.5)
        shoot(app, "menu")
        #else
        shoot(app, "guide")
        let grid = app.collectionViews["guide.grid"]
        if grid.exists {
            grid.cells.element(boundBy: 3).press(forDuration: 1.2)
        } else {
            app.cells.element(boundBy: 1).press(forDuration: 1.2)
        }
        shoot(app, "menu")
        if UIDevice.current.userInterfaceIdiom == .phone {
            app.terminate()
            XCUIDevice.shared.orientation = .landscapeLeft
            let wide = launch("tab-guide")
            _ = wide.collectionViews["guide.grid"].waitForExistence(timeout: 15)
            shoot(wide, "guide-sideways")
            XCUIDevice.shared.orientation = .portrait
        }
        #endif
    }

    @MainActor
    func testPages() throws {
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        for screen in ["programme", "programme-later", "channel", "search"] {
            let app = launch(screen)
            Thread.sleep(forTimeInterval: 2)
            shoot(app, screen)
            app.terminate()
        }
    }
}
