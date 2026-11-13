import XCTest

// #298 (batch L, 11 Nov 2026): Sport pages laid out at the Apple TV's fixed widths on screens that have less room. An
// 11-inch iPad in landscape: the Formula 1 page's session tiles needed about 1,330 pt of 1,146, so the page was wider
// than the screen and the banner's back button went off the left. The Apple TV: the tiles ran about 40 pt past the page's
// right edge. An iPad in portrait: the banner's buttons broke inside their words ("Watc/h"). An iPhone at the largest
// text size: the Sport header cut "Sport" to "S…". On PigTVTests/Fixtures/sport-pages-d43.json (times moved to the
// clock), no server. Screenshots go to the attachments (T3).
final class SportFitUITests: XCTestCase {
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

    private func launch(_ environment: [String: String] = [:], arguments: [String] = []) throws -> XCUIApplication {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PigTVTests/Fixtures/sport-pages-d43.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let delta = Date().timeIntervalSince1970 * 1000 - (json["now"] as? Double ?? 0)
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "front"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launchEnvironment["PIGTV_UI_TEST_PAGES_JSON"] = try JSONSerialization.data(withJSONObject: Self.shifted(json, by: delta))
            .base64EncodedString()
        app.launchArguments += arguments
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    #if os(iOS)
    private var device: String { min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) > 800 ? "ipad-11" : "ipad-mini" }
    #endif

    /// The Formula 1 page: every session tile and the circuit end inside the page (the standings' right edge) and the
    /// banner's back button starts on screen. Apple TV, and an iPad in both orientations (in portrait the row scrolls
    /// sideways, so only the banner is checked there).
    @MainActor
    func testTheFormula1PageFitsTheScreen() throws {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout only") }
        let orientations: [(UIDeviceOrientation, String)] = [(.landscapeLeft, "landscape"), (.portrait, "portrait")]
        #else
        let orientations: [(Int, String)] = [(0, "tv")]
        #endif
        for (orientation, name) in orientations {
            #if os(iOS)
            XCUIDevice.shared.orientation = orientation
            #else
            _ = orientation
            #endif
            let app = try launch(["PIGTV_UI_TEST_OPEN_SPORT": "Motorsport", "PIGTV_UI_TEST_FRONT_F1": "1"])
            let any = app.descendants(matching: .any)
            XCTAssertTrue(any["f1.session.race"].waitForExistence(timeout: 15), "\(name): the session tiles")
            Thread.sleep(forTimeInterval: 1)
            #if os(iOS)
            attach(app, "298-f1-\(device)-\(name)")
            #else
            attach(app, "298-f1-tv")
            #endif
            let window = app.windows.firstMatch.frame
            let back = any["sport.banner.back"]
            if back.exists {
                XCTAssertGreaterThanOrEqual(back.frame.minX, window.minX - 0.5, "\(name): the back button is off the left: \(back.frame)")
            }
            let banner = any["sport.banner"].frame
            XCTAssertGreaterThanOrEqual(banner.minX, window.minX - 0.5, "\(name): the banner starts off screen: \(banner)")
            XCTAssertLessThanOrEqual(banner.maxX, window.maxX + 0.5, "\(name): the banner ends off screen: \(banner)")
            // In portrait, and on an iPad mini in landscape (1,085 pt: less than five tiles at their narrowest and the
            // circuit), the row keeps its full tiles and scrolls sideways; elsewhere it fits the page.
            #if os(iOS)
            let fits = name != "portrait" && device != "ipad-mini"
            #else
            let fits = true
            #endif
            if fits {
                let edge = any["f1.standings.constructors"].firstMatch.frame.maxX
                let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'f1.session.'")).allElementsBoundByIndex
                XCTAssertGreaterThanOrEqual(tiles.count, 5)
                for tile in tiles + [any["f1.circuit"].firstMatch] {
                    print(String(format: "WIDTH298 %@ %@ x %.1f…%.1f edge %.1f", name, tile.identifier, tile.frame.minX, tile.frame.maxX, edge))
                    XCTAssertLessThanOrEqual(tile.frame.maxX, edge + 1, "\(name): \(tile.identifier) runs past the page's edge \(edge)")
                }
            }
            app.terminate()
        }
    }

    #if os(iOS)
    /// An iPad's Sport front page in both orientations: the hero's buttons sit on one line (none taller than the others,
    /// as a button whose words wrap is), inside the hero, left of the banner's list.
    @MainActor
    func testTheBannersButtonsKeepTheirWordsWhole() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout only") }
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            XCUIDevice.shared.orientation = orientation
            let app = try launch()
            let any = app.descendants(matching: .any)
            XCTAssertTrue(any["sport.banner"].waitForExistence(timeout: 15), "\(name): the banner")
            Thread.sleep(forTimeInterval: 1)
            attach(app, "298-banner-\(device)-\(name)")
            let buttons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sport.banner.hero.'")).allElementsBoundByIndex
            XCTAssertGreaterThanOrEqual(buttons.count, 2, "\(name): the hero's buttons")
            let list = any["sport.banner.list"].frame
            let heights = buttons.map(\.frame.height)
            print("WIDTH298 banner \(name) " + buttons.map { "\($0.identifier) \($0.frame)" }.joined(separator: ", "))
            // A wrapped label adds a line (about 20 pt); a shrunk one is a point or two shorter.
            XCTAssertLessThanOrEqual((heights.max() ?? 0) - (heights.min() ?? 0), 4, "\(name): a button is taller (its words wrapped): \(heights)")
            for button in buttons {
                XCTAssertLessThanOrEqual(button.frame.height, 60, "\(name): \(button.identifier) is two lines tall")
                if list.width > 0 { XCTAssertLessThanOrEqual(button.frame.maxX, list.minX, "\(name): \(button.identifier) runs under the list") }
            }
            app.terminate()
        }
    }
    #endif
}
