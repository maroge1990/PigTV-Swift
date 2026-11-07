import XCTest

// 18 Oct (app test team): the pig and the page title still sat at slightly different positions and sizes on every
// tab. Build 42 gave every tab the same PigPageHeader, but each page placed it with its own padding (0, 20, 24, 40,
// 48 pt) and its own top inset, and the Guide's taller trailing buttons re-centred the row. Cycling through the tabs,
// the title (and the pig beside it in the same row) must not move or change size. Runs on tvOS, iPad and iPhone
// (portrait), on the offline library fixture.
final class PageHeaderPlacementUITests: XCTestCase {
    @MainActor
    func testThePigAndTitleStayPutAcrossTabs() throws {
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "home"
        app.launch()
        // #216 (D-44): Sport · TV Guide · Recordings · Settings; the fixture opens on Sport, as the app does.
        let tabs = ["Sport", "TV Guide", "Recordings", "Settings"]
        var frames: [(String, CGRect)] = []

        func title(_ name: String) -> XCUIElement {
            app.staticTexts.matching(identifier: "page.header.title")
                .matching(NSPredicate(format: "label == %@", name)).firstMatch
        }
        func headerFrame(_ name: String) -> CGRect? {
            let element = title(name)
            guard element.waitForExistence(timeout: 15) else { return nil }
            // Let the tab's cross-fade and any first layout settle: two equal reads in a row.
            var last = element.frame
            _ = waitUntil(5) {
                Thread.sleep(forTimeInterval: 0.3)
                let now = element.frame
                defer { last = now }
                return now == last
            }
            return last
        }

        XCTAssertTrue(title("Sport").waitForExistence(timeout: 15), "the fixture did not open on Sport")
        for (index, name) in tabs.enumerated() {
            if index > 0 {
                #if os(tvOS)
                XCUIRemote.shared.press(.right)
                #else
                // iPad draws its tabs at the top, not as a tab bar
                let tab = app.tabBars.buttons[name].firstMatch
                (tab.exists ? tab : app.buttons[name].firstMatch).tap()
                #endif
            }
            let frame = try XCTUnwrap(headerFrame(name), "\(name): no page header title")
            frames.append((name, frame))
            print(String(format: "HEADER %@ x %.1f y %.1f h %.1f", name, frame.minX, frame.minY, frame.height))
        }
        let reference = frames[0].1
        for (name, frame) in frames.dropFirst() {
            XCTAssertEqual(frame.minX, reference.minX, accuracy: 0.5, "\(name): title x \(frame.minX), Sport \(reference.minX)")
            XCTAssertEqual(frame.minY, reference.minY, accuracy: 0.5, "\(name): title y \(frame.minY), Sport \(reference.minY)")
            XCTAssertEqual(frame.height, reference.height, accuracy: 0.5, "\(name): title height \(frame.height), Sport \(reference.height)")
        }
    }

    /// #243 (6 Nov audit): the Sport front page (C-R, the server's `sportFront`) had no pig-and-title header on tvOS and
    /// iPad, and its date read "Friday 6 November" where the guide's reads "Fri, 6 Nov". Its header sits where the TV
    /// Guide's does, with the same date.
    @MainActor
    func testTheSportFrontPageHeaderSitsWhereTheGuidesDoes() throws {
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PigTVTests/Fixtures/sport-front-0427.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let delta = Date().timeIntervalSince1970 * 1000 - (json["now"] as? Double ?? 0)
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "front"
        app.launchEnvironment["PIGTV_UI_TEST_FRONT_F1"] = "1"
        app.launchEnvironment["PIGTV_UI_TEST_FRONT_JSON"] = try JSONSerialization.data(withJSONObject: Self.shifted(json, by: delta))
            .base64EncodedString()
        app.launch()
        func title(_ name: String) -> XCUIElement {
            app.staticTexts.matching(identifier: "page.header.title").matching(NSPredicate(format: "label == %@", name)).firstMatch
        }
        let sport = title("Sport")
        XCTAssertTrue(sport.waitForExistence(timeout: 15), "the Sport front page has the shared page header")
        let date = Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        XCTAssertTrue(app.staticTexts[date].exists, "the header's date reads like the guide's: \(date)")
        let sportFrame = sport.frame
        #if os(tvOS)
        // up to the tab bar, then right to the TV Guide
        for _ in 0..<6 { XCUIRemote.shared.press(.up) }
        XCUIRemote.shared.press(.right)
        #else
        let tab = app.tabBars.buttons["TV Guide"].firstMatch
        (tab.exists ? tab : app.buttons["TV Guide"].firstMatch).tap()
        #endif
        let guide = title("TV Guide")
        XCTAssertTrue(guide.waitForExistence(timeout: 15), "the TV Guide")
        _ = waitUntil(5) { Thread.sleep(forTimeInterval: 0.3); return guide.frame.minY > 0 }
        XCTAssertEqual(guide.frame.minX, sportFrame.minX, accuracy: 0.5, "title x: Guide \(guide.frame.minX), Sport \(sportFrame.minX)")
        XCTAssertEqual(guide.frame.minY, sportFrame.minY, accuracy: 0.5, "title y: Guide \(guide.frame.minY), Sport \(sportFrame.minY)")
        XCTAssertEqual(guide.frame.height, sportFrame.height, accuracy: 0.5, "title height")
    }

    private static func shifted(_ value: Any, by delta: Double) -> Any {
        if var dict = value as? [String: Any] {
            for (key, inner) in dict {
                if ["now", "start", "end", "observedAt"].contains(key), let number = inner as? Double {
                    dict[key] = number + delta
                } else {
                    dict[key] = shifted(inner, by: delta)
                }
            }
            return dict
        }
        if let list = value as? [Any] { return list.map { shifted($0, by: delta) } }
        return value
    }
}
