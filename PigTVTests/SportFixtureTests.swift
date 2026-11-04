import XCTest
@testable import PigTV

// D-43 (Apple 99, part C, mock-up V2-League-1): a fixture league under its banner. The NFL from the server's own
// answer (`nfl-page-0379.json`: weeks 7 and 8, the eight divisions) and a C-T league (the AFL in `sport-pages-d43.json`:
// round 20 played, round 21 current with Collingwood live, one table of six columns): the rounds to switch between,
// the standings views (Division / Conference / Overall, else one table), the followed team marked, spoilers hidden, and
// a game's C-R card found for Watch and Record. Before Apple 99 the NFL page's own layout was embedded and a C-T league
// showed only its C-R cards.
final class SportFixtureTests: XCTestCase {
    // #228 (Mark's iPad test, 4 Nov 2026): the standings beside the games had six values held 44 pt wide in a 380 pt table,
    // so a row was wider than the table: it overflowed over the second column's scores and left the name a few letters.
    // Now a football row (P W D L GD Pts) leaves its name at least 120 pt (a followed row, with its star), and the games
    // keep two cards of at least 300 pt on an 11-inch iPad in landscape (1194 pt, 32 pt margins, a 24 pt gap).
    func testTheIPadStandingsLeaveTheNameRoomAndTheGamesTheirScores() {
        XCTAssertLessThan(SportFixtureMetrics.touchTableBefore.nameRoom(values: 6), 0, "the cause: the row was wider than the table")
        let table = SportFixtureMetrics.touchTable
        XCTAssertGreaterThanOrEqual(table.nameRoom(values: 6), 120)
        let card = (1194 - 2 * 32 - 24 - table.width - 14) / 2
        XCTAssertGreaterThanOrEqual(card, 300, "each game card \(card) pt")
        XCTAssertEqual(SportFixtureMetrics.tvTable.width, 680, "Apple TV unchanged")
    }

    private func nfl() throws -> NFLPage { try JSONDecoder().decode(NFLPage.self, from: try NFLPageTests.fixture()) }
    private func afl() throws -> LeaguePage { try SportPagesFixture.part(["leagues", "AFL"]) }

    func testTheNFLOpensOnTheCurrentWeekAndSwitchesToTheLastOne() throws {
        let league = FixtureText.nfl(try nfl(), following: ["Packers"], spoilerFree: false)
        XCTAssertEqual(league.rounds.map(\.label), ["Week 7", "Week 8"])
        XCTAssertEqual(FixtureText.openingRound(league), "8")
        XCTAssertEqual(FixtureText.round(nil, in: league)?.label, "Week 8")
        XCTAssertEqual(FixtureText.round("7", in: league)?.label, "Week 7", "the last week, chosen")
        XCTAssertEqual(FixtureText.round("99", in: league)?.label, "Week 8", "a round the answer no longer has: the opening one")
        XCTAssertTrue(league.awayFirst)
    }

    // Apple 99's Codex round (medium): the eight divisions in two groups, AFC and NFC, the followed team's first, each a
    // button press away; a view of four tables or fewer is one group; untitled tables go in runs of four. Before Apple 100
    // only the first four divisions were shown.
    func testEveryNFLDivisionIsReachable() throws {
        let league = FixtureText.nfl(try nfl(), following: ["Packers"], spoilerFree: false)
        let division = try XCTUnwrap(FixtureText.view(nil, in: league))
        let groups = FixtureText.groups(division)
        XCTAssertEqual(groups.map(\.name), ["NFC", "AFC"])
        XCTAssertEqual(groups.flatMap(\.tables).count, 8, "every division")
        XCTAssertEqual(groups[0].tables.first?.title, "NFC North")
        XCTAssertEqual(FixtureText.groups(try XCTUnwrap(FixtureText.view("Conference", in: league))).count, 1)
        var untitled = division
        untitled.tables = division.tables.map { var t = $0; t.title = nil; return t }
        XCTAssertEqual(FixtureText.groups(untitled).map(\.name), ["Tables 1–4", "Tables 5–8"])
    }

    func testTheNFLsStandingsHaveThreeViewsWithTheFollowedTeamsTableFirst() throws {
        let league = FixtureText.nfl(try nfl(), following: ["Packers"], spoilerFree: false)
        XCTAssertEqual(league.views.map(\.name), ["Division", "Conference", "Overall"])
        let division = try XCTUnwrap(FixtureText.view(nil, in: league))
        XCTAssertEqual(division.tables.count, 8)
        XCTAssertEqual(FixtureText.tables(division).first?.title, "NFC North", "the followed team's division first")
        XCTAssertEqual(FixtureText.view("Overall", in: league)?.tables.first?.rows.count, 32)
        XCTAssertTrue(FixtureText.tables(division).first?.rows.contains { $0.abbr == "GB" && $0.followed } == true)
        let game = try XCTUnwrap(league.rounds[1].games.first { $0.home.abbr == "GB" })
        XCTAssertTrue(game.followed)
        XCTAssertEqual(game.home.score, "27")
        XCTAssertEqual(game.home.record, "5-3")
    }

    func testSpoilerFreeHidesScoresRecordsAndDetail() throws {
        let league = FixtureText.nfl(try nfl(), following: [], spoilerFree: true)
        let games = league.rounds.flatMap(\.games)
        XCTAssertTrue(games.allSatisfy { $0.home.score == nil && $0.away.score == nil && $0.home.record == nil && $0.situation == nil })
        XCTAssertTrue(games.filter { $0.status == "done" }.allSatisfy { $0.detail == "Played" })
    }

    func testACTLeagueHasOneTableAndItsRounds() throws {
        let league = FixtureText.league(try afl(), league: "AFL", following: [], spoilerFree: false)
        XCTAssertEqual(league.rounds.map(\.label), ["Round 20", "Round 21"])
        XCTAssertEqual(FixtureText.round(nil, in: league)?.label, "Round 21")
        XCTAssertEqual(FixtureText.round("1:20", in: league)?.games.count, 3)
        XCTAssertEqual(league.views.count, 1, "no divisions: one table")
        let table = try XCTUnwrap(league.views.first?.tables.first)
        XCTAssertEqual(table.columns, ["P", "W", "L", "D", "Pts", "%"])
        XCTAssertEqual(table.rows.count, 18)
        XCTAssertEqual(table.rows.filter(\.followed).map(\.name), ["Collingwood"], "C-T's `following` id")
        let live = try XCTUnwrap(league.rounds[1].games.first { $0.status == "live" })
        XCTAssertEqual(live.home.name, "Collingwood")
        XCTAssertTrue(live.followed)
        XCTAssertEqual(live.home.score, "45")
        XCTAssertEqual(live.detail, "Q3 12:04")
        XCTAssertNil(league.rounds[1].games.first { $0.status == "scheduled" }?.home.score, "no score before the start")
    }

    func testACTLeagueSpoilerFree() throws {
        let league = FixtureText.league(try afl(), league: "AFL", following: [], spoilerFree: true)
        let live = try XCTUnwrap(league.rounds[1].games.first { $0.status == "live" })
        XCTAssertNil(live.home.score)
        XCTAssertEqual(live.detail, "Live")
    }

    func testAGamesWatchAndRecordUseItsCRCard() throws {
        let league = FixtureText.league(try afl(), league: "AFL", following: [], spoilerFree: false)
        let front = try SportPagesFixture.front()
        let live = try XCTUnwrap(league.rounds[1].games.first { $0.status == "live" })
        XCTAssertEqual(FixtureText.card(for: live, league: "AFL", in: front)?.id, "espn:australian-football/afl:5")
        let later = try XCTUnwrap(league.rounds[1].games.first { $0.home.name == "Adelaide Crows" || $0.away.name == "Adelaide Crows" })
        XCTAssertNil(FixtureText.card(for: later, league: "AFL", in: front), "no card: its own channels")
        XCTAssertEqual(FixtureText.event(live, league: "AFL").channels.first?.name, "Fox Footy HD")
    }
}

extension SportFixtureTests {
    /// #211 (rig T3, 2 Nov): the AFL's percentage is drawn to one decimal ("137.200" wrapped as "137." / "200").
    func testTheAFLPercentageHasOneDecimal() throws {
        XCTAssertEqual(FixtureText.standingValue("137.200", key: "percentage"), "137.2")
        XCTAssertEqual(FixtureText.standingValue("95", key: "percentage"), "95.0")
        XCTAssertEqual(FixtureText.standingValue("-", key: "percentage"), "-", "not a number: ESPN's text")
        XCTAssertEqual(FixtureText.standingValue("137.200", key: "points"), "137.200", "only the percentage")
        var page = try afl()
        page.standings[0].rows[0].values["percentage"] = "137.200"
        let league = FixtureText.league(page, league: "AFL", following: [], spoilerFree: false)
        XCTAssertEqual(league.views[0].tables[0].rows[0].values.last, "137.2")
    }
}

extension SportFrontLayoutTests {
    /// #211: a live card's clock is short ("OT1 10:00", "Q4 0:17"); the down and distance stay in the banner. Before
    /// Apple 138 the card drew "Overtime 1 · 10:00 · Down 1 · 10 yards · Yard line 65" and cut it.
    func testALiveCardsClockIsShort() throws {
        func game(_ league: String, period: Int, clock: String) throws -> SportFront {
            try Self.front { json in
                var games = json["games"] as? [[String: Any]] ?? []
                games[0]["league"] = league
                games[0]["progress"] = ["period": period, "clock": clock] as [String: Any]
                games[0]["situation"] = ["down": 1, "distance": 10, "yardLine": 65]
                json["games"] = games
            }
        }
        let nfl = try game("NFL", period: 5, clock: "10:00")
        let card = try XCTUnwrap(nfl.game("espn:soccer/eng.1:1"))
        XCTAssertEqual(SportFrontText.cardClock(card, in: nfl, hidden: false), "OT1 10:00")
        XCTAssertNotNil(SportFrontText.drawn(card, in: nfl, hidden: false).situation?.range(of: "Down 1"), "the banner keeps it")
        let q4 = try game("NFL", period: 4, clock: "0:17")
        XCTAssertEqual(SportFrontText.cardClock(try XCTUnwrap(q4.game("espn:soccer/eng.1:1")), in: q4, hidden: true), "Q4 0:17")
        let afl = try game("AFL", period: 3, clock: "12:01")
        XCTAssertEqual(SportFrontText.cardClock(try XCTUnwrap(afl.game("espn:soccer/eng.1:1")), in: afl, hidden: false), "Q3 12:01")
        let epl = try Self.front()
        XCTAssertEqual(SportFrontText.cardClock(try XCTUnwrap(epl.game("espn:soccer/eng.1:1")), in: epl, hidden: false), "67'")
    }
}
