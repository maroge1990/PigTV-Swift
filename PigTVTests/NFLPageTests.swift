import XCTest
@testable import PigTV

// C-Q (#21): the NFL page. `nfl-page-0379.json` is the server's own answer (server 0379's sportPageNFL over its ESPN
// fixtures captured 31 Oct 2026 08:42 Melbourne: week 7's finals, week 8 with Thursday's Panthers at Packers final and
// the rest to come, one channel on Ravens at Bills, the eight divisions). Before Apple 86 there is no NFL page.
@MainActor
final class NFLPageTests: XCTestCase {
    static func fixture() throws -> Data {
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            for url in bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [] {
                if url.lastPathComponent == "nfl-page-0379.json" { return try Data(contentsOf: url) }
            }
        }
        throw XCTSkip("nfl-page-0379.json is not in the test bundle")
    }

    private func page() throws -> NFLPage { try JSONDecoder().decode(NFLPage.self, from: try Self.fixture()) }

    func testTheServersAnswerDecodesAndOpensOnTheCurrentWeek() throws {
        let p = try page()
        XCTAssertTrue(p.available)
        XCTAssertEqual(p.weeks.map(\.label), ["Week 7", "Week 8"])
        XCTAssertEqual(NFLPageText.openingWeek(p), 8)
        XCTAssertEqual(Set(p.weeks[1].byes), ["HOU", "NO", "NYG", "SF"])
        XCTAssertEqual(p.teams.count, 32)
        XCTAssertEqual(p.standings.count, 8)
        let thursday = p.weeks[1].games[0]
        XCTAssertEqual([thursday.away.abbr, thursday.home.abbr], ["CAR", "GB"])
        XCTAssertEqual(thursday.status, .done)
        XCTAssertEqual(NFLPageText.score(thursday.home, game: thursday, spoilerFree: false), "27")
        XCTAssertNil(NFLPageText.score(thursday.home, game: thursday, spoilerFree: true), "spoiler-free hides the score")
        XCTAssertEqual(NFLPageText.status(thursday, spoilerFree: true), "Played")
        let next = p.weeks[1].games[1]
        XCTAssertNil(NFLPageText.score(next.home, game: next, spoilerFree: false), "0 before kick-off is not a score")
    }

    func testAGameIsAnEventOnItsChannelsOwnTimes() throws {
        let p = try page()
        let ravens = try XCTUnwrap(p.weeks[1].games.first { $0.away.abbr == "BAL" })
        let event = NFLPageText.event(ravens, in: p)
        XCTAssertEqual(event.title, "Ravens at Bills")
        XCTAssertEqual(event.league, "NFL")
        XCTAssertEqual(event.best?.name, "Fox Sports 505")
        XCTAssertEqual(event.startTime, ravens.startTime - 1_800_000, "the channel's own airing (#20)")
        let other = try XCTUnwrap(p.weeks[1].games.first { $0.away.abbr == "TEN" })
        XCTAssertNil(NFLPageText.event(other, in: p).best, "not in the guide yet")
    }

    func testStandingsViewsDivisionConferenceOverall() throws {
        let p = try page()
        let division = NFLPageText.standings(p, view: .division, following: "GB")
        XCTAssertEqual(division.first?.title, "NFC North", "the followed team's division first")
        XCTAssertEqual(division.count, 8)
        let conference = NFLPageText.standings(p, view: .conference, following: "GB")
        XCTAssertEqual(conference.map(\.title), ["NFC", "AFC"])
        XCTAssertEqual(conference[0].rows.map(\.rank), Array(1...16), "by seed")
        let overall = NFLPageText.standings(p, view: .overall, following: nil)
        XCTAssertEqual(overall.count, 1)
        XCTAssertEqual(overall[0].rows.count, 32)
        let shares = overall[0].rows.map { NFLPageText.winShare($0.row) }
        XCTAssertEqual(shares, shares.sorted(by: >))
    }

    func testFollowingOffersEveryTeamByNameAndLastAndNext() throws {
        let p = try page()
        let teams = NFLPageText.followable(p)
        XCTAssertEqual(teams.count, 32)
        XCTAssertEqual(teams.first?.full, "Arizona Cardinals", "alphabetical, never in standings order")
        let (last, next) = NFLPageText.lastAndNext(p, team: "GB")
        XCTAssertEqual(last?.away.abbr, "CAR", "Thursday's game")
        XCTAssertNil(next, "Green Bay plays no other game in these two weeks")
    }

    func testTheFollowedTeamIsKeptAndSentInThePreferences() throws {
        let prefs = try JSONDecoder().decode(SportPagePreferences.self, from: Data(#"{"spoilerFree":true,"following":{"F1":"Lando Norris","NFL":"GB"}}"#.utf8))
        XCTAssertEqual(prefs.nflFollowing, "GB")
        XCTAssertEqual(prefs.f1Following, "Lando Norris")
        let older = try JSONDecoder().decode(SportPagePreferences.self, from: Data(#"{"spoilerFree":false,"following":{"F1":null}}"#.utf8))
        XCTAssertNil(older.nflFollowing, "a server before 0379")
        let round = try JSONDecoder().decode(SportPagePreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(round, prefs)
    }

    func testANotReadyAnswerDecodesAsUnavailable() throws {
        let p = try JSONDecoder().decode(NFLPage.self, from: Data(#"{"available":false}"#.utf8))
        XCTAssertFalse(p.available)
        XCTAssertTrue(p.weeks.isEmpty)
    }
}
