import XCTest

#if os(iOS)
/// #58 option B on iPad and iPhone (Apple 406-407; run by the `ios` tier on one iPad and one iPhone): Skip break and Go to
/// live at the scrub bar's end with the controls up, Auto-skip breaks there and working, Start over and Go to live on the
/// live bar; and (Codex review of 406) a finger held on Skip break past the 4 s idle deadline keeps the controls, so the
/// press still skips. Needs the review movie (Tools/generate-brand-review-media.sh).
final class TouchPlayerButtonsUITests: XCTestCase {
    private static let media = "/private/tmp/pig-deep-media/review.mp4"

    override func setUp() { continueAfterFailure = false }

    private func launch(_ screen: String, _ env: [String: String] = [:]) throws -> XCUIApplication {
        guard FileManager.default.fileExists(atPath: Self.media) else {
            throw XCTSkip("Generate local review media with Tools/generate-brand-review-media.sh first.")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = screen
        app.launchEnvironment["PIGTV_UI_TEST_MEDIA"] = Self.media
        for (key, value) in env { app.launchEnvironment[key] = value }
        app.launch()
        return app
    }

    /// `button` sits at the scrub bar's end: right of the bar, on its line.
    private func atBarsEnd(_ button: XCUIElement, _ bar: XCUIElement, _ name: String) {
        XCTAssertGreaterThanOrEqual(button.frame.minX, bar.frame.maxX - 1, "\(name) \(button.frame) is not after the bar \(bar.frame)")
        XCTAssertLessThan(abs(button.frame.midY - bar.frame.midY), 30, "\(name) \(button.frame) is not on the bar's line \(bar.frame)")
    }

    private func showControls(_ app: XCUIApplication, _ id: String) {
        if !app.buttons[id].exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 3), "the controls did not show")
    }

    @MainActor
    func testARecordingsSkipBreakIsAtTheBarsEndAndAHeldPressOutlastsTheIdleTimer() throws {
        let app = try launch("recording-player")
        // The controls hide after 4 idle seconds; the break (10-20 s) brings the floating Skip break.
        XCTAssertTrue(app.buttons["recording.skipBreak"].waitForExistence(timeout: 30), "no break")
        showControls(app, "recording.playPause")
        let skip = app.buttons["recording.skipBreak"]
        XCTAssertTrue(skip.exists && skip.isHittable, "Skip break with the controls up")
        atBarsEnd(skip, app.descendants(matching: .any)["player.scrub"], "Skip break")
        XCTAssertTrue(app.buttons["recording.autoSkip"].exists, "Auto-skip breaks on touch (#369)")
        // Held past the idle deadline: the controls stay, and the release skips the break.
        skip.press(forDuration: 5.5)
        XCTAssertTrue(waitUntil(3) { !app.buttons["recording.skipBreak"].exists }, "the held press did not skip the break")
        XCTAssertTrue(app.buttons["recording.playPause"].exists, "the controls hid under the finger")
        // Auto-skip flips.
        let auto = app.buttons["recording.autoSkip"]
        XCTAssertTrue(auto.label.hasSuffix("Off"), auto.label)
        auto.tap()
        XCTAssertTrue(waitUntil(3) { app.buttons["recording.autoSkip"].label.hasSuffix("On") }, app.buttons["recording.autoSkip"].label)
        app.buttons["recording.autoSkip"].tap() // leave it off for the next run
        app.terminate()
    }

    @MainActor
    func testARecordingStillBeingMadeHasGoToLiveAtTheBarsEnd() throws {
        let app = try launch("recording-player-golive")
        let live = app.buttons["recording.goLive"]
        XCTAssertTrue(live.waitForExistence(timeout: 20), "no Go to live")
        app.buttons["recording.playPause"].tap() // paused: the controls stay
        XCTAssertTrue(live.isHittable)
        atBarsEnd(live, app.descendants(matching: .any)["player.scrub"], "Go to live")
        XCTAssertFalse(app.descendants(matching: .any)["recording.goLive"].frame.minY < app.frame.height * 0.3,
                       "Go to live is no longer in the top bar")
        app.terminate()
    }

    @MainActor
    func testLiveTVHasStartOverAtTheBarsStartAndGoToLiveAtItsEnd() throws {
        let app = try launch("player", ["PIGTV_UI_TEST_START_OVER": "1"])
        let pause = app.buttons["player.playPause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 20))
        if !pause.isHittable { showControls(app, "player.playPause") }
        pause.tap() // paused: the controls stay, and the play is behind live
        let bar = app.descendants(matching: .any)["player.scrub"]
        let startOver = app.buttons["player.startOver"], goLive = app.buttons["player.goToLive"]
        XCTAssertTrue(startOver.waitForExistence(timeout: 5), "no Start over (#308)")
        XCTAssertTrue(goLive.waitForExistence(timeout: 5), "no Go to live")
        XCTAssertLessThanOrEqual(startOver.frame.maxX, bar.frame.minX + 1, "Start over \(startOver.frame) is not before the bar \(bar.frame)")
        atBarsEnd(goLive, bar, "Go to live")
        app.terminate()
    }
}
#endif
