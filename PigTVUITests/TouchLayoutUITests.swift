import XCTest

#if os(iOS)
// 18 Oct (app test team), iPhone and iPad. Run on an iOS simulator (the tvOS tiers skip it): offline fixtures, no server.
final class TouchLayoutUITests: XCTestCase {
    private static let media = "/private/tmp/pig-deep-media/review.mp4"

    /// Bug: on an upright iPhone the Guide fitted its regular header, so Search kept its text and wrapped onto a second
    /// line. It is an icon now: about as wide as it is tall.
    @MainActor
    func testPhoneGuideSearchIsIconOnly() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone layout only") }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "guide"
        app.launch()
        let search = app.buttons["Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Guide Search button not shown")
        let frame = search.frame
        XCTAssertLessThan(frame.width, frame.height * 1.6, "Search is \(frame.width) x \(frame.height): it still carries its text")
    }

    /// Bug: the touch player's TV Guide pill did nothing Close doesn't (it closed the player onto the Guide tab).
    @MainActor
    func testTouchPlayerHasNoTVGuideButton() throws {
        guard FileManager.default.fileExists(atPath: Self.media) else {
            throw XCTSkip("Generate local review media with Tools/generate-brand-review-media.sh first.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "player"
        app.launchEnvironment["PIGTV_UI_TEST_MEDIA"] = Self.media
        app.launch()
        XCTAssertTrue(app.buttons["player.channels"].waitForExistence(timeout: 20), "player controls not shown")
        XCTAssertFalse(app.buttons["player.guide"].exists, "the player still has a TV Guide button")
    }

    /// Apple 118 (Mark's check of 5a): on an upright iPhone Change recording's actions wrapped (Save changes clipped,
    /// "Cancel recording" on two lines), its eyebrow was cut and the chosen Finish late sat off screen. The actions are
    /// stacked full width, and the chosen chip is in view.
    @MainActor
    func testPhoneRecordPageStacksItsActionsAndShowsTheChosenChip() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone layout only") }
        XCUIDevice.shared.orientation = .portrait
        for screen in ["record-change", "record"] {
            let app = XCUIApplication()
            app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = screen
            app.launch()
            let primary = app.buttons["record.schedule"]
            XCTAssertTrue(primary.waitForExistence(timeout: 15), "\(screen): no record page")
            let width = app.windows.firstMatch.frame.width
            XCTAssertGreaterThan(primary.frame.width, width * 0.7, "\(screen): the primary is \(primary.frame.width) wide of \(width)")
            let close = app.buttons["record.close"]
            XCTAssertGreaterThan(close.frame.minY, primary.frame.maxY - 1, "\(screen): the actions are not stacked")
            if screen == "record-change" {
                let cancel = app.buttons["record.cancelRecording"]
                XCTAssertGreaterThan(cancel.frame.width, width * 0.7, "Cancel recording is not full width")
                XCTAssertLessThan(cancel.frame.height, primary.frame.height * 1.5, "Cancel recording wraps")
                let chosen = app.buttons["record.after"]
                XCTAssertTrue(chosen.exists)
                XCTAssertTrue(chosen.label.contains("15 min"), "the chosen Finish late is shown: \(chosen.label)")
            }
            // #253: Start early / Finish late are one line each, a menu on the right inside the card (chips ran past its edge).
            for id in ["record.before", "record.after"] {
                let menu = app.buttons[id]
                XCTAssertTrue(menu.exists, "\(screen): no \(id) menu")
                XCTAssertLessThanOrEqual(menu.frame.maxX, width - 8, "\(screen): \(id) runs off the card: \(menu.frame)")
            }
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'record.after.'")).count, 0, "\(screen): no chips")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "iphone-\(screen)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    /// #255: in iPhone landscape a programme's or channel's menu ran off the bottom of the screen (its last rows could not
    /// be reached). It is capped at the screen and its rows scroll.
    @MainActor
    func testPhoneLandscapeGuideMenuReachesItsLastRow() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone layout only") }
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "guide"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.collectionViews.firstMatch.cells.firstMatch.waitForExistence(timeout: 15), "no guide")
        sleep(1)
        // A programme in the grid (its menu has the Record section, the longest).
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55)).press(forDuration: 1.2)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'menu.'"))
        XCTAssertTrue(app.buttons["menu.recordThis"].waitForExistence(timeout: 5), "no programme menu")
        let screen = app.windows.firstMatch.frame
        func lastRowIsOnScreen(_ which: String) throws {
            let last = try XCTUnwrap(rows.allElementsBoundByIndex.max { $0.frame.maxY < $1.frame.maxY })
            let scroll = app.scrollViews["menu.scroll"]
            if scroll.exists { scroll.swipeUp(); sleep(1) }
            XCTAssertLessThanOrEqual(last.frame.maxY, screen.maxY, "\(which): \(last.identifier) runs off the screen: \(last.frame)")
        }
        try lastRowIsOnScreen("the programme's menu")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "iphone-landscape-menu"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// #258: on iPad, Settings' header and pig sat level with every tab's on first opening, then 64 pt higher (at the top
    /// of the screen) every later time: the system split view dropped the tab bar's inset.
    @MainActor
    func testPadSettingsHeaderStaysPutOnASecondVisit() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "home"
        app.launch()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        let title = app.staticTexts.matching(identifier: "page.header.title").matching(NSPredicate(format: "label == 'Settings'")).firstMatch
        settings.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        sleep(1)
        let first = title.frame
        app.buttons["TV Guide"].firstMatch.tap()
        sleep(1)
        settings.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertEqual(title.frame.minY, first.minY, accuracy: 1, "the header moved: \(first) then \(title.frame)")
    }
}
#endif
