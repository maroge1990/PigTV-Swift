import XCTest

#if os(iOS)
/// #352 (Mark, 18 Nov 2026, TestFlight 319): on the iPhone the Sport front page jolted as the hero turned into the
/// pinned strip (#264). The strip took its own room above the page's ScrollView, so the page's frame (and every row on
/// it) moved by the strip's room the moment it showed; and the hand-over stalled the main thread mid-drag, so the scroll
/// view took the drag for a flick and carried the page on (~135 pt, about half the runs). Scrolled slowly in equal steps
/// up past the hand-over and back down past it, a row moves by the same amount each step (the finger's), with no
/// extra jump when the strip comes or goes.
final class SportPhoneStripScrollUITests: XCTestCase {
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

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testThePageMovesOnlyWithTheFingerAsTheHeroBecomesTheStrip() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone layout only") }
        XCUIDevice.shared.orientation = .portrait
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PigTVTests/Fixtures/sport-pages-d43.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let delta = Date().timeIntervalSince1970 * 1000 - (json["now"] as? Double ?? 0)
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "front"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        app.launchEnvironment["PIGTV_UI_TEST_PAGES_JSON"] = try JSONSerialization.data(withJSONObject: Self.shifted(json, by: delta))
            .base64EncodedString()
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.front.carousel"].waitForExistence(timeout: 15), "the follows' carousel")
        let strip = any["sport.front.strip"]
        XCTAssertFalse(strip.exists, "no strip at the top")
        // A row well below the carousel, followed through the steps.
        let rows = any.matching(NSPredicate(format: "identifier BEGINSWITH 'sport.rail.header.'"))
        let first = rows.element(boundBy: rows.count > 1 ? 1 : 0)
        XCTAssertTrue(first.exists, "a sport's header row")
        let row = any[first.identifier] // followed by its own id, never by its place in the list
        let window = app.windows.firstMatch.frame
        // One slow drag of 40 pt (Mark's "scroll slowly", about half a second) that holds at its end: no momentum, the page
        // goes exactly where the finger leaves it. Faster (`.slow` is a flick of a tenth of a second), a frame dropped by
        // the simulator near the drag's end made the scroll view read the finger as still moving and coast on.
        func drag(_ dy: CGFloat) -> CGFloat {
            let before = row.frame.minY
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                .withOffset(CGVector(dx: 0, dy: window.height * (dy < 0 ? 0.7 : 0.45)))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)),
                        withVelocity: XCUIGestureVelocity(80), thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 0.8) // the strip's own move has settled
            return before - row.frame.minY
        }
        // Up past the hand-over (the strip shows), then back down past it (the hero returns).
        var trace: [String] = []
        var up: [CGFloat] = [], down: [CGFloat] = []
        var shownAt: Int?, hiddenAt: Int?
        for step in 0..<14 {
            up.append(drag(-40))
            trace.append(String(format: "up %d: %.1f%@", step, up[step], strip.exists ? " strip" : ""))
            if strip.exists, shownAt == nil { shownAt = step; attach(app, "352-strip-shows-step-\(step)") }
            if let shownAt, step >= shownAt + 2 { break }
        }
        for step in 0..<14 {
            down.append(-drag(40))
            trace.append(String(format: "down %d: %.1f%@", step, down[step], strip.exists ? " strip" : ""))
            if !strip.exists, hiddenAt == nil { hiddenAt = step; attach(app, "352-hero-returns-step-\(step)") }
            if let hiddenAt, step >= hiddenAt + 2 { break }
        }
        print("352 trace: \(trace)")
        XCTAssertNotNil(shownAt, "the page scrolled up past the hand-over: \(trace)")
        XCTAssertNotNil(hiddenAt, "the page scrolled back down past the hand-over: \(trace)")
        // A drag can give up a few points to the scroll view's touch slop (it then moves less), never more than the
        // finger; at the hand-over the row moves with the finger, with no jump either way.
        for (name, moves, at) in [("up", up, shownAt), ("down", down, hiddenAt)] {
            let typical = moves.sorted()[moves.count / 2]
            for (step, move) in moves.enumerated() {
                XCTAssertLessThanOrEqual(move, typical + 6, "\(name) step \(step) moved the row \(move) pt, the finger's steps \(typical) pt: \(trace)")
            }
            // The touch slop takes up to ~7 pt of a drag; the old jump was the strip's room (52 pt) against the finger.
            if let at { XCTAssertGreaterThanOrEqual(moves[at], typical - 12, "\(name): at the hand-over (step \(at)) the row moved \(moves[at]) pt: \(trace)") }
        }
    }
}
#endif
