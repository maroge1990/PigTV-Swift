import XCTest

// 18 Oct (app test team): the pig and the page title still sat at slightly different positions and sizes on every
// tab. Build 42 gave every tab the same PigPageHeader, but each page placed it with its own padding (0, 20, 24, 40,
// 48 pt) and its own top inset, and the Guide's taller trailing buttons re-centred the row. Cycling through the tabs,
// the title (and the pig beside it in the same row) must not move or change size. Runs on tvOS, iPad and iPhone
// (portrait), on the offline Home fixture.
final class PageHeaderPlacementUITests: XCTestCase {
    @MainActor
    func testThePigAndTitleStayPutAcrossTabs() throws {
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "home"
        app.launch()
        // Apple 89 (D-39): Sport first, Home is "TV" second. The Home fixture opens on TV (the app itself opens on Sport:
        // SportFrontUITests), so the cycle starts by moving to Sport.
        let tabs = ["Sport", "TV", "TV Guide", "Recordings", "Settings"]
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

        XCTAssertTrue(title("TV").waitForExistence(timeout: 15), "the fixture did not open on TV")
        #if os(tvOS)
        XCUIRemote.shared.press(.left)
        #else
        app.tabBars.buttons["Sport"].firstMatch.tap()
        #endif
        for (index, name) in tabs.enumerated() {
            if index > 0 {
                #if os(tvOS)
                XCUIRemote.shared.press(.right)
                #else
                app.tabBars.buttons[name].firstMatch.tap()
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
}
