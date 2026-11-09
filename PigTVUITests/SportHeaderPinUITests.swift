import XCTest

// #263 (Mark, 9 Nov 2026): on the Sport front page the header (the pig, "Sport", the date, the scores chip) moved with
// the page, where the TV Guide keeps it fixed and scrolls its content beneath. On the iPhone the header was inside the
// page's ScrollView; on the Apple TV and the iPad the ScrollView drew its rails outside its own frame
// (`.scrollClipDisabled()`), over the header. Scrolling the page must leave the header where it was and nothing drawn
// over it: its frame is unchanged and the screen's pixels across the header's row are the same before and after.
// #264 (option B): once the page has scrolled past the banner, the strip it shrinks to is pinned under the header
// (`sport.front.strip`); at the top there is none. On iPad and iPhone a tap on the strip goes back to the full hero.
// Runs on tvOS, iPad and iPhone (portrait) on the offline fixtures.
final class SportHeaderPinUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static func shifted(_ value: Any, by delta: Double) -> Any {
        if var dict = value as? [String: Any] {
            for (key, inner) in dict {
                if let number = inner as? Double, number > 1e12, !(inner is Bool) { dict[key] = number + delta } else { dict[key] = shifted(inner, by: delta) }
            }
            return dict
        }
        if let list = value as? [Any] { return list.map { shifted($0, by: delta) } }
        return value
    }

    private func launch() throws -> XCUIApplication {
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "front"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        #if os(tvOS)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root
            .appendingPathComponent("PigTVTests/Fixtures/sport-front-0381.json"))) as? [String: Any])
        app.launchEnvironment["PIGTV_UI_TEST_FRONT_JSON"] = try JSONSerialization.data(withJSONObject: json).base64EncodedString()
        #else
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root
            .appendingPathComponent("PigTVTests/Fixtures/sport-pages-d43.json"))) as? [String: Any])
        let delta = Date().timeIntervalSince1970 * 1000 - (json["now"] as? Double ?? 0)
        app.launchEnvironment["PIGTV_UI_TEST_PAGES_JSON"] = try JSONSerialization.data(withJSONObject: Self.shifted(json, by: delta))
            .base64EncodedString()
        #endif
        app.launch()
        return app
    }

    /// The screen's pixels across the header's row (full width), as PNG data.
    private func band(_ app: XCUIApplication, _ row: CGRect) -> Data? {
        let image = app.screenshot().image
        guard let cg = image.cgImage else { return nil }
        let scale = CGFloat(cg.width) / image.size.width
        let rect = CGRect(x: 0, y: row.minY * scale, width: CGFloat(cg.width), height: row.height * scale).integral
        guard let crop = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: crop).pngData()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testTheHeaderStaysPutAndUncoveredWhileThePageScrolls() throws {
        let app = try launch()
        let title = app.staticTexts.matching(identifier: "page.header.title")
            .matching(NSPredicate(format: "label == %@", "Sport")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "the Sport front page's header")
        XCTAssertTrue(app.descendants(matching: .any)["sport.front"].waitForExistence(timeout: 15), "the page")
        #if os(tvOS)
        // Focus off the tab bar first (the page does not scroll for it), so the tab's glow is the same in both shots.
        XCUIRemote.shared.press(.down)
        #endif
        Thread.sleep(forTimeInterval: 1.5)
        let before = title.frame
        // The header's row: 20 points through the middle of the title, across the screen (the pig and the scores chip
        // share it). The title's frame is taller than its words: above them is the tab bar's focus glow, below them the
        // page's faded top edge, and both change as focus moves.
        let row = CGRect(x: before.minX, y: before.midY - 10, width: before.width, height: 20)
        let pixels = band(app, row)
        attach(app, "263-before-scroll")
        let strip = app.descendants(matching: .any)["sport.front.strip"]
        XCTAssertFalse(strip.exists, "#264: no strip while the full banner shows")

        #if os(tvOS)
        for _ in 0..<10 { XCUIRemote.shared.press(.down); Thread.sleep(forTimeInterval: 0.4) }
        #else
        let page = app.scrollViews.containing(.any, identifier: "sport.front").firstMatch
        page.swipeUp(velocity: .slow)
        page.swipeUp(velocity: .slow)
        #endif
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, "263-after-scroll")

        XCTAssertTrue(title.exists && title.isHittable, "the header is still on screen")
        let after = title.frame
        print(String(format: "HEADER263 before y %.1f after y %.1f", before.minY, after.minY))
        XCTAssertEqual(after.minY, before.minY, accuracy: 0.5, "the header moved with the page")
        XCTAssertEqual(after.minX, before.minX, accuracy: 0.5, "the header moved sideways")
        XCTAssertNotNil(pixels)
        XCTAssertEqual(band(app, row), pixels, "something was drawn over the header's row as the page scrolled")

        XCTAssertTrue(strip.waitForExistence(timeout: 5), "#264: the banner shows as the strip once it has scrolled under")
        XCTAssertGreaterThanOrEqual(strip.frame.minY, after.maxY, "the strip sits under the header")
        #if os(iOS)
        strip.tap()
        XCTAssertTrue(waitUntil(5) { !strip.exists }, "a tap on the strip goes back to the full hero")
        #else
        // Codex (Apple 190 round 1, medium): back up the rails, every focused control sits below the strip while it
        // shows, never beneath it; at the top the full hero is back.
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        for step in 0..<12 {
            XCUIRemote.shared.press(.up)
            Thread.sleep(forTimeInterval: 0.6)
            if strip.exists, focused.exists {
                XCTAssertGreaterThanOrEqual(focused.frame.minY, strip.frame.maxY - 0.5,
                                            "step \(step): \(focused.identifier) is beneath the strip")
            }
            if !strip.exists { break }
        }
        XCTAssertFalse(strip.exists, "up from the rails comes back to the full hero")
        #endif
    }
}
