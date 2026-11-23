import XCTest

#if os(tvOS)
/// #58, #308 (option B, Apple 406): the Apple TV players' two lines of buttons on the remote: the row (Pause first) and
/// the progress bar (Start over at its start; Skip break, then Go to live, at its end). Before: one row, no Pause in the
/// live row, no Start over, and Down hid the chrome. Needs the review movie (Tools/generate-brand-review-media.sh).
final class PlayerButtonsUITests: XCTestCase {
    private static let media = "/private/tmp/pig-deep-media/review.mp4"

    override func setUp() { continueAfterFailure = false }

    private func launch(_ screen: String, _ env: [String: String] = [:]) throws -> (XCUIApplication, XCUIElement) {
        guard FileManager.default.fileExists(atPath: Self.media) else {
            throw XCTSkip("Generate local review media with Tools/generate-brand-review-media.sh first.")
        }
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = screen
        app.launchEnvironment["PIGTV_UI_TEST_MEDIA"] = Self.media
        for (key, value) in env { app.launchEnvironment[key] = value }
        app.launch()
        let surface = app.buttons[screen == "player" ? "review.livePlayer" : "review.recordingPlayer"]
        XCTAssertTrue(surface.waitForExistence(timeout: 20))
        return (app, surface)
    }

    private func state(_ element: XCUIElement) -> String { element.value as? String ?? "" }

    private func expect(_ element: XCUIElement, _ part: String, _ message: String = "", timeout: TimeInterval = 3) {
        XCTAssertTrue(waitUntil(timeout) { self.state(element).contains(part) }, "\(message) wanted \(part): \(state(element))")
    }

    @MainActor
    func testLiveTVRowStartsOnPauseAndDownReachesStartOverAndGoToLive() throws {
        let (app, surface) = try launch("player", ["PIGTV_UI_TEST_START_OVER": "1"])
        expect(surface, "line=row; button=playPause", "the chrome opens on Pause", timeout: 5)
        XCUIRemote.shared.press(.select) // Pause, from the row: Go to live joins the bar
        XCUIRemote.shared.press(.down)
        expect(surface, "line=bar; button=goLive", "Down lands on the bar's right end")
        XCUIRemote.shared.press(.left)
        expect(surface, "line=bar; button=startOver")
        XCUIRemote.shared.press(.up)
        expect(surface, "line=row; button=playPause", "Up returns where the row was left")
        XCUIRemote.shared.press(.up)
        expect(surface, "hidden", "Up from the row hides")
        XCUIRemote.shared.press(.select)
        expect(surface, "info; action=0; line=row; button=playPause", "the chrome opens on the row's first button again")
        // #308: Start over ends the live play (the recording of the programme plays from its start).
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.left)
        expect(surface, "button=startOver")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil(10) { !surface.exists }, "Start over did not end the live play")
        app.terminate()
    }

    @MainActor
    func testRecordingBreakSelectsSkipBreakOnTheBarAndGoToLiveFollowsIt() throws {
        let (app, surface) = try launch("recording-player-golive")
        // The chrome hides after 6 idle seconds; Up brings it back before the break at 10 s.
        expect(surface, "hidden", timeout: 12)
        XCUIRemote.shared.press(.up)
        expect(surface, "info; action=0; line=row; button=playPause")
        expect(surface, "line=bar; button=skipBreak", "a break starting selects Skip break", timeout: 8)
        XCUIRemote.shared.press(.right)
        expect(surface, "line=bar; button=goLive", "Go to live after Skip break")
        XCUIRemote.shared.press(.up)
        expect(surface, "line=row; button=playPause")
        XCUIRemote.shared.press(.right)
        expect(surface, "line=row; button=autoSkip")
        XCUIRemote.shared.press(.down)
        expect(surface, "line=bar; button=skipBreak", "Down lands on Skip break (the right end's first)")
        XCUIRemote.shared.press(.down)
        expect(surface, "hidden", "Down from the bar hides")
        app.terminate()
    }
}
#endif
