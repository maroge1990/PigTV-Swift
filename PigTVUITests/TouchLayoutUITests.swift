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
                let chosen = app.buttons["record.after.15"]
                XCTAssertTrue(chosen.exists)
                XCTAssertLessThanOrEqual(chosen.frame.maxX, width, "the chosen Finish late is off screen: \(chosen.frame)")
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "iphone-\(screen)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }
}
#endif
