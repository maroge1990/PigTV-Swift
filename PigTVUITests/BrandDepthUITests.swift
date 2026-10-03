import XCTest

#if os(tvOS)
/// Runs real remote commands against offline media and existing application screens.
final class BrandDepthUITests: XCTestCase {
    private func launch(_ screen: String, _ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = screen
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = mode
        app.launchEnvironment["PIGTV_UI_TEST_MEDIA"] = "/private/tmp/pig-deep-media/review.mp4"
        if screen == "settings" { app.launchArguments = ["-pigtv.appearance", mode] }
        app.launch()
        return app
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 1) // Let native presentation and focus transitions settle.
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func value(_ element: XCUIElement) -> String { element.value as? String ?? "" }
    private func expect(_ element: XCUIElement, _ part: String) {
        XCTAssertTrue(NSPredicate(format: "value CONTAINS %@", part).evaluate(with: element), value(element))
    }
    private func requireMedia() throws {
        guard FileManager.default.fileExists(atPath: "/private/tmp/pig-deep-media/review.mp4") else {
            throw XCTSkip("Generate local review media with Tools/generate-brand-review-media.sh before running player visual checks.")
        }
    }
    @MainActor
    func testLivePlayerOverlaysAndTrackSelectionInBothAppearances() throws {
        try requireMedia()
        for mode in ["light", "dark"] {
            let app = launch("player", mode)
            let surface = app.buttons["review.livePlayer"]
            XCTAssertTrue(surface.waitForExistence(timeout: 15))
            // Pause preserves the chrome while we inspect it.
            XCUIRemote.shared.press(.playPause)
            sleep(1)
            expect(surface, "info")
            shot(app, "live-info-\(mode)")
            XCUIRemote.shared.press(.right)
            XCUIRemote.shared.press(.right)
            XCUIRemote.shared.press(.select)
            expect(surface, "tracks")
            shot(app, "live-tracks-\(mode)")
            let before = value(surface).components(separatedBy: "selected=").last
            XCUIRemote.shared.press(.down)
            XCUIRemote.shared.press(.select)
            XCTAssertNotEqual(value(surface).components(separatedBy: "selected=").last, before, "Track selection did not change")
            XCUIRemote.shared.press(.down)
            XCUIRemote.shared.press(.select)
            expect(surface, "subtitles.off")
            shot(app, "live-subtitles-off-\(mode)")
            XCUIRemote.shared.press(.down)
            XCUIRemote.shared.press(.select)
            XCTAssertFalse(value(surface).contains("subtitles.off"))
            shot(app, "live-tracks-selected-\(mode)")
            XCUIRemote.shared.press(.menu)
            expect(surface, "hidden")
            XCUIRemote.shared.press(.down)
            expect(surface, "channels")
            shot(app, "live-channels-\(mode)")
            let channel = value(surface)
            XCUIRemote.shared.press(.down)
            XCTAssertNotEqual(value(surface), channel, "Channel cursor did not move")
            shot(app, "live-channels-focus-\(mode)")
            XCUIRemote.shared.press(.menu)
            expect(surface, "hidden")
            XCUIRemote.shared.press(.right)
            expect(surface, "scrub")
            shot(app, "live-scrub-\(mode)")
            XCUIRemote.shared.press(.menu)
            expect(surface, "hidden")
            XCUIRemote.shared.press(.select)
            expect(surface, "info")
            app.terminate()
        }
    }
    @MainActor
    func testRecordingPlayerRemoteControlsInBothAppearances() throws {
        try requireMedia()
        for mode in ["light", "dark"] {
            let app = launch("recording-player", mode)
            let surface = app.buttons["review.recordingPlayer"]
            XCTAssertTrue(surface.waitForExistence(timeout: 15))
            XCUIRemote.shared.press(.playPause)
            expect(surface, "paused=true")
            shot(app, "recorded-info-\(mode)")
            XCUIRemote.shared.press(.right)
            XCUIRemote.shared.press(.select)
            expect(surface, "autoSkip=true")
            shot(app, "recorded-auto-skip-\(mode)")
            XCUIRemote.shared.press(.select) // auto-skip off, so the break prompt can be inspected
            expect(surface, "autoSkip=false")
            XCUIRemote.shared.press(.menu)
            expect(surface, "hidden")
            XCUIRemote.shared.press(.right)
            expect(surface, "scrub")
            shot(app, "recorded-scrub-\(mode)")
            XCUIRemote.shared.press(.menu)
            expect(surface, "hidden")
            expect(surface, "break=1")
            shot(app, "recorded-skip-break-prompt-\(mode)")
            XCUIRemote.shared.press(.select) // Hidden chrome: Select skips the current break.
            sleep(1)
            XCTAssertFalse(value(surface).contains("break=1"), "Skip break did not leave the break")
            expect(surface, "hidden")
            XCUIRemote.shared.press(.select)
            expect(surface, "info")
            app.terminate()
        }
    }
    private func focus(_ app: XCUIApplication, label: String) {
        let target = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<16 {
            if target.hasFocus { return }
            let current = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
            let a = current.frame, b = target.frame
            if abs(a.midY - b.midY) > max(25, b.height / 2) {
                XCUIRemote.shared.press(a.midY < b.midY ? .down : .up)
            } else { XCUIRemote.shared.press(a.midX < b.midX ? .right : .left) }
            // A press lands asynchronously (a segmented control reports its new
            // focus late on a slow runner); judging the stale snapshot sent the
            // next press back the way it came.
            for _ in 0..<15 where !target.hasFocus { Thread.sleep(forTimeInterval: 0.1) }
        }
        XCTAssertTrue(target.hasFocus, "Could not focus \(label): \(app.debugDescription)")
    }
    @MainActor
    func testSubmenuDialogsAndCancellationInBothAppearances() throws {
        for mode in ["light", "dark"] {
            var app = launch("record", mode)
            XCTAssertTrue(app.buttons["record.schedule"].waitForExistence(timeout: 10))
            shot(app, "record-options-\(mode)")
            focus(app, label: "Cancel")
            XCUIRemote.shared.press(.select)
            XCTAssertFalse(app.buttons["record.schedule"].exists)
            shot(app, "record-cancel-return-\(mode)")
            app.terminate()
            app = launch("recording", mode)
            focus(app, label: "Delete")
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.buttons["Delete recording and file"].waitForExistence(timeout: 5))
            shot(app, "recording-delete-confirmation-\(mode)")
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(app.buttons["Delete"].exists)
            app.terminate()
            app = launch("settings", mode)
            focus(app, label: "Sign out")
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.buttons["Stay signed in"].waitForExistence(timeout: 5))
            shot(app, "sign-out-confirmation-\(mode)")
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(app.buttons["appearance.dark"].exists)
            app.terminate()
            app = launch("search", mode)
            XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10))
            XCUIRemote.shared.press(.select)
            shot(app, "search-keyboard-\(mode)")
            XCUIRemote.shared.press(.menu)
            shot(app, "search-keyboard-dismissed-\(mode)")
            XCTAssertTrue(app.buttons["Show channels"].isHittable)
            app.terminate()
        }
    }

    @MainActor
    func testScheduledRecordingCancellationAndSettingsFooter() throws {
        for mode in ["light", "dark"] {
            let app = launch("recordings", mode)
            focus(app, label: "Scheduled")
            XCUIRemote.shared.press(.select)
            shot(app, "recordings-scheduled-\(mode)")
            focus(app, label: "Cancel schedule")
            XCUIRemote.shared.press(.select)
            shot(app, "schedule-cancel-confirmation-\(mode)")
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(app.buttons["Cancel schedule"].exists)
            app.terminate()
            let settings = launch("settings", mode)
            focus(settings, label: "Sign out")
            for _ in 0..<6 { XCUIRemote.shared.press(.down) }
            shot(settings, "settings-diagnostics-\(mode)")
            settings.terminate()
        }
    }

    @MainActor
    func testGuideCategoryFocusWhileScrollingInBothAppearances() throws {
        for mode in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "guide"
            app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = mode
            app.launchEnvironment["PIGTV_UI_TEST_LONG_CATEGORIES"] = "1"
            app.launch()
            focus(app, label: "All")
            shot(app, "category-focus-start-\(mode)")
            for _ in 0..<12 { XCUIRemote.shared.press(.right) }
            let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
            XCTAssertTrue(focused.label.hasPrefix("Category "), focused.label)
            shot(app, "category-focus-scrolled-\(mode)")
            for _ in 0..<12 { XCUIRemote.shared.press(.left) }
            XCTAssertTrue(app.buttons["All"].hasFocus)
            shot(app, "category-focus-return-\(mode)")
            app.terminate()
        }
    }

    @MainActor
    func testPlaybackErrorFocusAndPairingCancellation() throws {
        try requireMedia()
        for mode in ["light", "dark"] {
            for screen in ["player-error", "recording-error"] {
                let app = launch(screen, mode)
                focus(app, label: "Retry")
                shot(app, "\(screen)-retry-focus-\(mode)")
                focus(app, label: screen == "player-error" ? "Back to channels" : "Back")
                shot(app, "\(screen)-back-focus-\(mode)")
                app.terminate()
            }
            let app = launch("pairing", mode)
            focus(app, label: "Cancel pairing")
            shot(app, "pairing-code-\(mode)")
            XCUIRemote.shared.press(.select)
            XCTAssertFalse(app.buttons["Cancel pairing"].exists)
            XCTAssertTrue(app.secureTextFields.firstMatch.exists)
            shot(app, "pairing-cancel-return-\(mode)")
            app.terminate()
        }
    }

}
#endif
