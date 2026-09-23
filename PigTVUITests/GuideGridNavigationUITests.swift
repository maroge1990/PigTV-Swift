import XCTest

#if os(tvOS)
// A2.1: remote navigation across the UIKit guide grid (Labs → New guide on),
// on the offline guide fixture (PIGTV_UI_TEST_SCREEN=guide; no server).
// Mirrors GuideNavigationUITests and adds the Up/Down time-column check.
final class GuideGridNavigationUITests: XCTestCase {
    private let tile = "Sky Sports Main Event"

    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    private func focusedLabel(_ app: XCUIApplication) -> String {
        let element = focused(app)
        return element.exists ? element.label : "<none>"
    }

    /// The grid's committed viewport (ISO time), published as its
    /// accessibility value.
    private func viewport(_ app: XCUIApplication) -> String {
        (app.collectionViews["guide.grid"].value as? String) ?? "<none>"
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "guide"
        app.launchArguments += ["-pigtv.labs.newGuide", "YES"]
        app.launch()
        XCTAssertTrue(app.collectionViews["guide.grid"].waitForExistence(timeout: 10), "new guide grid not shown")
        return app
    }

    /// Down from the tab bar into the grid, then Right onto a programme in
    /// the first row.
    private func enterFirstRow(_ app: XCUIApplication) {
        for _ in 0..<8 where focusedLabel(app) != tile && !focusedLabel(app).contains(", ") {
            XCUIRemote.shared.press(.down)
        }
        if focusedLabel(app) == tile { XCUIRemote.shared.press(.right) }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testRightThroughTheDayAndLeftBackToTheTile() throws {
        let app = launch()
        enterFirstRow(app)
        let start = focusedLabel(app)
        XCTAssertTrue(start.hasPrefix("\(tile), "), "no first-row programme focused: \(start)")
        let startViewport = viewport(app)
        var labels = [start]
        for _ in 0..<12 {
            XCUIRemote.shared.press(.right)
            labels.append(focusedLabel(app))
        }
        print("New guide Right sequence: \(labels) viewport \(startViewport) → \(viewport(app))")
        attach(app, "New guide after 12 × Right")
        XCTAssertGreaterThanOrEqual(Set(labels).count, 8, "focus stalled: \(labels)")
        XCTAssertTrue(labels.allSatisfy { $0.hasPrefix("\(tile), ") }, "Right left the row: \(labels)")
        XCTAssertNotEqual(viewport(app), startViewport, "the grid did not scroll")
        var back: [String] = []
        for _ in 0..<20 {
            XCUIRemote.shared.press(.left)
            back.append(focusedLabel(app))
            if !back.last!.contains(", ") { break }
        }
        print("New guide Left sequence: \(back) viewport \(viewport(app))")
        XCTAssertEqual(back.last, tile, "Left did not reach the channel tile: \(back)")
        XCTAssertEqual(viewport(app), startViewport, "Left did not return to the live baseline")
    }

    @MainActor
    func testUpAndDownKeepTheTimeColumn() throws {
        let app = launch()
        enterFirstRow(app)
        for _ in 0..<3 { XCUIRemote.shared.press(.right) }
        let startLabel = focusedLabel(app)
        let startFrame = focused(app).frame
        let startViewport = viewport(app)
        XCTAssertTrue(startLabel.contains(", "), "no programme focused: \(startLabel)")
        var labels = [startLabel]
        for direction in [XCUIRemote.Button.down, .down, .down, .up, .up, .up] {
            XCUIRemote.shared.press(direction)
            let label = focusedLabel(app)
            let frame = focused(app).frame
            labels.append(label)
            XCTAssertTrue(label.contains(", "), "Up/Down left the programmes: \(labels)")
            // The new cell lies under the same time: the frames overlap
            // horizontally, and the grid did not move sideways.
            XCTAssertTrue(frame.maxX > startFrame.minX && frame.minX < startFrame.maxX,
                          "\(label) \(frame) is not in the column of \(startLabel) \(startFrame)")
            XCTAssertEqual(viewport(app), startViewport, "Up/Down moved the grid sideways")
        }
        print("New guide Up/Down sequence: \(labels)")
        attach(app, "New guide after Down/Up")
        XCTAssertEqual(labels.last, startLabel, "Up did not return to the starting programme: \(labels)")
        XCTAssertNotEqual(labels[1], startLabel, "Down did not move: \(labels)")
        // Further down the grid scrolls vertically only, and the focused row
        // stays wholly inside the grid (below the time header).
        let grid = app.collectionViews["guide.grid"].frame
        for _ in 0..<10 {
            XCUIRemote.shared.press(.down)
            let frame = focused(app).frame
            XCTAssertGreaterThanOrEqual(frame.minY, grid.minY - 1, "\(focusedLabel(app)) is under the time header")
            XCTAssertLessThanOrEqual(frame.maxY, grid.maxY + 1, "\(focusedLabel(app)) is below the grid")
            XCTAssertEqual(viewport(app), startViewport, "Down moved the grid sideways")
        }
        attach(app, "New guide after 10 more × Down")
        for _ in 0..<10 { XCUIRemote.shared.press(.up) }
        let top = focused(app).frame
        XCTAssertEqual(focusedLabel(app), startLabel, "Up did not return to the first row")
        XCTAssertGreaterThanOrEqual(top.minY, grid.minY - 1, "\(focusedLabel(app)) is under the time header")
    }
}
#endif
