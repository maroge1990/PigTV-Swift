import XCTest

#if os(iOS)
// D-44 (R5-Front-iPhone, Apple 139): the iPhone Sport front page on PigTVTests/Fixtures/sport-pages-d43.json (times moved
// to the clock): the follows' carousel, one card per sport of fixture rows, a sport's header opens its page, and
// spoiler-free says so and draws no score. Run on an iPhone simulator (the tvOS tiers skip it); before Apple 139 the
// iPhone drew the tiles-and-hero-band page (no carousel).
final class SportPhoneFrontUITests: XCTestCase {
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

    private func launch(spoilers: Bool = false, idiom: UIUserInterfaceIdiom = .phone,
                        environment: [String: String] = [:]) throws -> XCUIApplication {
        guard UIDevice.current.userInterfaceIdiom == idiom else { throw XCTSkip("\(idiom == .pad ? "iPad" : "iPhone") layout only") }
        XCUIDevice.shared.orientation = .portrait
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PigTVTests/Fixtures/sport-pages-d43.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let delta = Date().timeIntervalSince1970 * 1000 - (json["now"] as? Double ?? 0)
        let app = XCUIApplication()
        app.launchEnvironment["PIGTV_UI_TEST_SCREEN"] = "front"
        app.launchEnvironment["PIGTV_UI_TEST_APPEARANCE"] = "dark"
        if spoilers { app.launchEnvironment["PIGTV_UI_TEST_SPOILERS"] = "1" }
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launchEnvironment["PIGTV_UI_TEST_PAGES_JSON"] = try JSONSerialization.data(withJSONObject: Self.shifted(json, by: delta))
            .base64EncodedString()
        app.launch()
        return app
    }

    @MainActor
    func testTheCarouselAndOneCardPerSport() throws {
        let app = try launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.front.carousel"].waitForExistence(timeout: 15), "the follows' carousel")
        XCTAssertTrue(any["sport.front.follow.0"].exists, "the first follow's card")
        XCTAssertEqual(any["sport.front.scores"].label, "Scores shown")
        XCTAssertTrue(any.matching(NSPredicate(format: "identifier BEGINSWITH 'sport.front.group.'")).count >= 2, "a card per sport")
        XCTAssertTrue(any.matching(NSPredicate(format: "identifier BEGINSWITH 'sport.front.game.'")).count >= 2, "fixture rows")
        let header = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sport.rail.header.'")).firstMatch
        XCTAssertTrue(header.exists)
        let sport = String(header.identifier.dropFirst("sport.rail.header.".count))
        header.tap()
        XCTAssertTrue(any["sport.page.\(sport)"].waitForExistence(timeout: 5), "the header opens \(sport)'s page")
    }

    @MainActor
    func testSpoilerFreeSaysSoAndDrawsNoScore() throws {
        let app = try launch(spoilers: true)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["sport.front.carousel"].waitForExistence(timeout: 15))
        XCTAssertEqual(any["sport.front.scores"].label, "Scores hidden")
        let scored = any.matching(NSPredicate(format: "label MATCHES '.*[0-9]+–[0-9]+.*'"))
        XCTAssertEqual(scored.count, 0, "no score anywhere: \(scored.allElementsBoundByIndex.map(\.label))")
    }

    /// D-44 (Apple 142, R5-*-iPhone, #177): a sport's page on the iPhone is the front page's pattern (the league's
    /// carousel, its games grouped as fixture rows), and the league's rounds and standings are a page of their own.
    /// Before Apple 142 the iPhone drew the Apple TV page squeezed (no carousel, no league page).
    @MainActor
    func testASportPageIsTheCarouselAndRowsWithItsStandingsOnAPageOfTheirOwn() throws {
        let app = try launch()
        let any = app.descendants(matching: .any)
        let header = app.buttons["sport.rail.header.Australian football"]
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        header.tap()
        XCTAssertTrue(any["sport.page.Australian football"].waitForExistence(timeout: 5))
        XCTAssertTrue(any["sport.page.phone.carousel"].waitForExistence(timeout: 5), "the league's carousel")
        XCTAssertTrue(any["sport.page.group.Live"].exists, "the live games as rows")
        XCTAssertTrue(any["sport.page.game.espn:australian-football/afl:5"].exists)
        let more = app.buttons["sport.page.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        XCTAssertTrue(any["sport.page.more.AFL"].waitForExistence(timeout: 5), "the league's own page")
        app.buttons["sport.page.back"].firstMatch.tap()
        XCTAssertTrue(any["sport.page.phone.carousel"].waitForExistence(timeout: 5), "back on the sport's page")
    }

    /// D-44 (Apple 142): an iPad in portrait stacks a league's panels, so the AFL standings sit inside the page rather
    /// than running off its right edge beside the round's games. Run on an iPad simulator. Before Apple 142 the table
    /// was drawn beside the games at a fixed width, wider than the space left.
    @MainActor
    func testAnIPadInPortraitStacksTheStandingsInsideThePage() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = try launch(idiom: .pad, environment: ["PIGTV_UI_TEST_OPEN_SPORT": "Australian football"])
        let table = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'sport.fixture.table.'")).firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 15), "the standings")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(table.frame.minX, window.minX, "the table starts inside the page")
        XCTAssertLessThanOrEqual(table.frame.maxX, window.maxX + 1, "the table ends inside the page: \(table.frame) in \(window)")
        let grid = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'sport.fixture.grid.'")).firstMatch
        XCTAssertGreaterThan(table.frame.minY, grid.frame.maxY - 1, "under the round's games, not beside them")
    }
}
#endif
