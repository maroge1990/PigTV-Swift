import XCTest
@testable import PigTV

// D-43 (Apple 99, part A): the banner's rows and the hero's kicker say the catalogue's label ("Premier League",
// "International (men)", C-U `sports/catalog`), not the canonical code, and a followed name is "YOUR DRIVER", "YOUR
// PLAYER", "YOUR FIGHTER" or "YOUR TEAM" by sport. Before Apple 99 the rows said "EPL" and every kicker "YOUR TEAM", and
// every cricket league showed the same page (Codex medium, Apple 98).
final class SportLabelsTests: XCTestCase {
    private static let catalog = #"""
    {"sports":[{"sport":"Football","leagues":[{"league":"EPL","label":"Premier League","heading":"Domestic leagues"},
      {"league":"Champions League","label":"Champions League","heading":"Europe"}]},
     {"sport":"Cricket","leagues":[{"league":"Cricket","label":"International (men)","heading":"International"},{"league":"WBBL","label":"WBBL","heading":null}]}]}
    """#

    private func labels() throws -> [String: String] {
        SportLabels.labels(try JSONDecoder().decode(SportCatalog.self, from: Data(Self.catalog.utf8)))
    }

    func testALeagueIsCalledByItsCatalogueLabelElseItsCode() throws {
        let labels = try labels()
        XCTAssertEqual(SportLabels.label("EPL", in: labels), "Premier League")
        XCTAssertEqual(SportLabels.label("Cricket", in: labels), "International (men)")
        XCTAssertEqual(SportLabels.label("NBA", in: labels), "NBA", "not in the catalogue: the code")
        XCTAssertEqual(SportLabels.label("EPL", in: [:]), "EPL", "no catalogue yet (or no sportFollows): the code")
    }

    func testTheSportPagesRowsAndTheHerosKickerSayTheLabel() throws {
        let front = try SportFrontLayoutTests.front()
        let now = Date(timeIntervalSince1970: front.now / 1000)
        let items = SportPageRules.leagueItems("Football", in: front, now: now, labels: try labels())
        XCTAssertEqual(items.map(\.title), ["Premier League", "Champions League"])
        XCTAssertEqual(items.map(\.id), ["EPL", "Champions League"], "the row's id stays the league's code")
        let game = try XCTUnwrap(front.game("espn:soccer/eng.1:1"))
        let hero = SportFrontLayout.hero(game, in: front, hidden: false, now: now, labels: try labels())
        XCTAssertEqual(hero.kicker, "LIVE · FOOTBALL · PREMIER LEAGUE · YOUR TEAM")
    }

    func testTheKickerNamesADriverPlayerFighterOrTeam() throws {
        let front = try SportFrontLayoutTests.front()
        let now = Date(timeIntervalSince1970: front.now / 1000)
        let race = try XCTUnwrap(front.game("espn:racing/f1:1"))
        XCTAssertTrue(SportFrontLayout.hero(race, in: front, hidden: false, now: now).kicker.hasSuffix("· YOUR DRIVER"),
                      SportFrontLayout.hero(race, in: front, hidden: false, now: now).kicker)
        XCTAssertEqual(SportLabels.yours(sport: "Motorsport"), "YOUR DRIVER")
        XCTAssertEqual(SportLabels.yours(sport: "Tennis"), "YOUR PLAYER")
        XCTAssertEqual(SportLabels.yours(sport: "Golf"), "YOUR PLAYER")
        XCTAssertEqual(SportLabels.yours(sport: "Combat"), "YOUR FIGHTER")
        XCTAssertEqual(SportLabels.yours(sport: "Football"), "YOUR TEAM")
    }

    func testEachCricketLeagueIsItsOwnContent() {
        let international = SportPageRules.content(league: "Cricket", sport: "Cricket", f1: true, nfl: true, cricket: true)
        let wbbl = SportPageRules.content(league: "WBBL", sport: "Cricket", f1: true, nfl: true, cricket: true)
        XCTAssertNotEqual(international, wbbl, "selecting another cricket league changes the page")
        XCTAssertEqual(wbbl, .cricket("WBBL"))
    }

    func testEachPageNeedsItsServerFlag() {
        XCTAssertEqual(SportPageRules.content(league: "AFL", sport: "Australian football", f1: true, nfl: true, cricket: true,
                                              leagues: ["AFL"]), .league)
        XCTAssertEqual(SportPageRules.content(league: "AFL", sport: "Australian football", f1: true, nfl: true, cricket: true), .games,
                       "not in sportPageLeagues: the C-R games")
        XCTAssertEqual(SportPageRules.content(league: "UFC", sport: "Combat", f1: true, nfl: true, cricket: true, events: true), .events)
        XCTAssertEqual(SportPageRules.content(league: "UFC", sport: "Combat", f1: true, nfl: true, cricket: true), .games,
                       "without sportPageEvents: the C-R games")
        XCTAssertEqual(SportPageRules.content(league: "NASCAR", sport: "Motorsport", f1: true, nfl: true, cricket: true, events: true), .events)
        XCTAssertEqual(SportPageRules.content(league: "MotoGP", sport: "Motorsport", f1: true, nfl: true, cricket: true), .motorCards)
    }
}
