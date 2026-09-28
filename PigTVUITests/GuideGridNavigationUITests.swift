import XCTest

#if os(tvOS)
// A2.1: remote navigation across the UIKit guide grid (the only tvOS grid since build 27),
// on the offline guide fixture (PIGTV_UI_TEST_SCREEN=guide; no server).
// Covers Left/Right through the day and the Up/Down time-column check.
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

    /// A2.1 follow-up: Now after moving right returns the grid to the live
    /// baseline and focus to what is on now in the same row.
    @MainActor
    func testNowAfterMovingRight() throws {
        let app = launch()
        enterFirstRow(app)
        XCTAssertTrue(focusedLabel(app).hasPrefix("\(tile), "), "no first-row programme focused: \(focusedLabel(app))")
        let baseline = viewport(app)
        for _ in 0..<6 { XCUIRemote.shared.press(.right) }
        let later = focusedLabel(app)
        XCTAssertNotEqual(viewport(app), baseline, "the grid did not scroll")
        // Build 22: Now sits in the header next to Earlier/Later, and Up
        // from the grid's top row lands on it.
        XCUIRemote.shared.press(.up)
        let deadlineUp = Date().addingTimeInterval(2)
        while focusedLabel(app) != "Now" && Date() < deadlineUp { usleep(100_000) }
        attach(app, "New guide after Up from the top row")
        XCTAssertEqual(focusedLabel(app), "Now", "Up from the top row did not reach Now")
        XCUIRemote.shared.press(.select)
        let deadline = Date().addingTimeInterval(3)
        while !focusedLabel(app).hasPrefix("\(tile), ") && Date() < deadline { usleep(200_000) }
        attach(app, "New guide after Now")
        // The live baseline (the current half hour; it may have moved on
        // during the test).
        let half = (Date().timeIntervalSince1970 / 1800).rounded(.down) * 1800
        let current = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: half))
        XCTAssertTrue([baseline, current].contains(viewport(app)), "Now did not return to the live baseline: \(viewport(app))")
        let now = focusedLabel(app)
        XCTAssertTrue(now.hasPrefix("\(tile), ") && now != later, "focus did not follow the grid to the first row: \(now)")
        // It is the programme on now: everything left of it has finished,
        // so Left goes straight to the tile without moving the grid.
        let atNow = viewport(app)
        XCUIRemote.shared.press(.left)
        XCTAssertEqual(focusedLabel(app), tile, "focus after Now was not on the live programme (\(now))")
        XCTAssertEqual(viewport(app), atNow)
    }

    /// Build 22: Earlier/Later keep focus on their header button, so
    /// repeated presses keep moving the grid.
    @MainActor
    func testLaterAndEarlierKeepFocusOnTheHeader() throws {
        let app = launch()
        enterFirstRow(app)
        let baseline = viewport(app)
        XCUIRemote.shared.press(.up)
        let deadline = Date().addingTimeInterval(2)
        while focusedLabel(app) != "Now" && Date() < deadline { usleep(100_000) }
        XCTAssertEqual(focusedLabel(app), "Now")
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        XCTAssertEqual(focusedLabel(app), "Later")
        var seen: [String] = [baseline]
        for _ in 0..<3 {
            XCUIRemote.shared.press(.select)
            usleep(600_000)
            XCTAssertEqual(focusedLabel(app), "Later", "Later took focus away")
            seen.append(viewport(app))
        }
        attach(app, "New guide after 3 × Later")
        XCTAssertEqual(Set(seen).count, 4, "Later did not move the grid each time: \(seen)")
        XCUIRemote.shared.press(.left)
        XCTAssertEqual(focusedLabel(app), "Earlier")
        XCUIRemote.shared.press(.select)
        usleep(600_000)
        XCTAssertEqual(focusedLabel(app), "Earlier", "Earlier took focus away")
        XCTAssertEqual(viewport(app), seen[2], "Earlier did not step back half an hour")
        // Down returns to the grid.
        XCUIRemote.shared.press(.down)
        var path: [String] = []
        for _ in 0..<4 where !focusedLabel(app).contains(", ") && focusedLabel(app) != tile {
            path.append(focusedLabel(app)); XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(focusedLabel(app).contains(", ") || focusedLabel(app) == tile, "Down did not reach the grid: \(path)")
    }

    /// Build 33 ("the guide hits a wall moving forward in time"): the fixture's
    /// synthetic programmes reach `GuideFixtures.forwardHorizon` (26 h) past
    /// now, well past the old hard-coded 24 h grid width. Moving right must
    /// reach past the 24 h mark and land on real next-day programmes, not
    /// stall at the old boundary.
    @MainActor
    func testMovingRightPast24HoursReachesTheNextDaysProgrammes() throws {
        let app = launch()
        enterFirstRow(app)
        XCTAssertTrue(focusedLabel(app).hasPrefix("\(tile), "), "no first-row programme focused: \(focusedLabel(app))")
        let startViewport = viewport(app)
        guard let start = ISO8601DateFormatter().date(from: startViewport) else {
            return XCTFail("could not parse the starting viewport: \(startViewport)")
        }
        let past24Hours = start.addingTimeInterval(24 * 3600)
        var labels: [String] = []
        var reachedNextDay = false
        for _ in 0..<60 {
            XCUIRemote.shared.press(.right)
            let label = focusedLabel(app)
            labels.append(label)
            XCTAssertTrue(label.hasPrefix("\(tile), "), "focus left the row or stalled: \(labels.suffix(5))")
            if let now = ISO8601DateFormatter().date(from: viewport(app)), now >= past24Hours {
                reachedNextDay = true
                break
            }
        }
        attach(app, "New guide after moving right past 24 h")
        XCTAssertTrue(reachedNextDay, "the grid never reached 24 h ahead of the start — still hits the old wall: \(labels.suffix(10))")
        XCTAssertTrue(focusedLabel(app).hasPrefix("\(tile), "), "no programme focused once past 24 h: \(focusedLabel(app))")
        XCTAssertGreaterThanOrEqual(Set(labels.suffix(20)).count, 4,
                                    "focus stalled repeating the same cells near the boundary: \(labels.suffix(20))")
    }

    /// A long press on a programme offers the old grid's menu; after the
    /// details cover closes, focus is back on that programme.
    @MainActor
    func testLongPressMenuAndFocusAfterDetails() throws {
        let app = launch()
        enterFirstRow(app)
        XCUIRemote.shared.press(.right)
        let programme = focusedLabel(app)
        XCTAssertTrue(programme.hasPrefix("\(tile), "), "no programme focused: \(programme)")
        XCUIRemote.shared.press(.select, forDuration: 1.5)
        XCTAssertTrue(app.otherElements["Programme details"].waitForExistence(timeout: 3), "no context menu")
        XCTAssertTrue(app.otherElements["Channel and favourites"].exists)
        attach(app, "New guide long-press menu")
        // The menu opens on its first item, Programme details.
        XCUIRemote.shared.press(.select)
        sleep(2)
        attach(app, "Programme details cover")
        XCTAssertFalse(app.otherElements["Channel and favourites"].exists, "the menu did not close")
        XCTAssertNotEqual(focusedLabel(app), programme, "no details cover opened")
        XCUIRemote.shared.press(.menu)
        let deadline = Date().addingTimeInterval(4)
        while focusedLabel(app) != programme && Date() < deadline { usleep(200_000) }
        XCTAssertEqual(focusedLabel(app), programme, "focus did not return to the programme after details")
    }
}
#endif
