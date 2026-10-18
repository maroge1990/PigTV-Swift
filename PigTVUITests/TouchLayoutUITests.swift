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
}
#endif
