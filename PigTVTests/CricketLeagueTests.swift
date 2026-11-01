import XCTest
@testable import PigTV

// D-43 (Apple 99, part D, mock-up V2-Cricket-1; Apple 98's Codex medium): the Cricket page under a sport page's banner
// shows the selected league. With two followed cricket leagues (International (men) and WBBL, `sport-pages-d43.json`),
// the internationals show the 3rd Test as the lead with its tour, and the WBBL its own matches, the Test then among the
// other leagues'; a Sheffield Shield match (a catalogue league not followed here) is never an international's. Before
// Apple 99 both leagues showed the same page.
final class CricketLeagueTests: XCTestCase {
    private let labels = ["Cricket": "International (men)", "WBBL": "WBBL", "Sheffield Shield": "Sheffield Shield", "BBL": "BBL"]

    private func page() throws -> CricketPage { try SportPagesFixture.part(["cricket"]) }
    private func scope(_ league: String) throws -> CricketLeagueScope {
        CricketLeagueScope(league: league, leagues: ["Cricket", "WBBL"], labels: labels, games: try SportPagesFixture.front().games)
    }

    func testTheInternationalsLeadWithTheTestAndItsTour() throws {
        let shown = CricketLeagueFilter.apply(try page(), scope: try scope("Cricket"))
        XCTAssertEqual(shown.lead?.id, "1525661")
        XCTAssertEqual(shown.series?.name, "Australia in South Africa")
        XCTAssertEqual(Set(shown.mine.compactMap(\.competition)), ["West Indies in Bangladesh", "India in New Zealand"],
                       "other tours: the only International group followed")
        XCTAssertTrue(shown.others.allSatisfy { ["WBBL", "Sheffield Shield"].contains($0.competition ?? "") })
    }

    func testSwitchingToTheWBBLChangesTheMatches() throws {
        let page = try page()
        let international = CricketLeagueFilter.apply(page, scope: try scope("Cricket"))
        let wbbl = CricketLeagueFilter.apply(page, scope: try scope("WBBL"))
        XCTAssertNil(wbbl.lead, "the Test is not the WBBL's")
        XCTAssertNil(wbbl.series)
        XCTAssertEqual(Set(wbbl.mine.map(\.id)), ["1543947", "1543948", "1543949", "1543950"])
        XCTAssertTrue(wbbl.others.contains { $0.id == "1525661" }, "the Test among the other leagues'")
        XCTAssertTrue(Set(wbbl.mine.map(\.id)).isDisjoint(with: Set(international.mine.map(\.id) + [international.lead?.id ?? ""])))
        XCTAssertFalse(wbbl.isEmpty)
    }

    func testALeagueWithNothingFallsBackToItsCRGames() throws {
        let scope = CricketLeagueScope(league: "BBL", leagues: ["Cricket", "BBL"], labels: labels, games: [])
        XCTAssertTrue(CricketLeagueFilter.apply(try page(), scope: scope).isEmpty)
    }

    func testTheCRCardNamesTheMatchsLeague() throws {
        let scope = try scope("WBBL")
        XCTAssertEqual(CricketLeagueFilter.league(ofMatch: "1543947", competition: "Something else", scope: scope), "WBBL")
        XCTAssertEqual(CricketLeagueFilter.league(ofMatch: "9", competition: "Sheffield Shield", scope: scope), "Sheffield Shield")
        XCTAssertEqual(CricketLeagueFilter.league(ofMatch: "9", competition: "England in India", scope: scope), "Cricket")
    }

    // Apple 99's Codex round (medium): with both International groups followed, a tour match with no C-R card leads
    // neither, whichever group comes first; it is among the others on both pages. Before Apple 100 the first group took it.
    func testAMatchOfNoKnownLeagueLeadsNoLeague() throws {
        let page = try page()
        for leagues in [["Cricket", "Women's Cricket"], ["Women's Cricket", "Cricket"]] {
            for league in leagues {
                let shown = CricketLeagueFilter.apply(page, scope: CricketLeagueScope(league: league, leagues: leagues, labels: labels))
                XCTAssertNil(shown.lead, "\(league) first in \(leagues): the Test is neither group's")
                XCTAssertTrue(shown.others.contains { $0.id == "1525661" }, "\(league): the Test among the others")
                XCTAssertTrue(shown.mine.isEmpty, "\(league): no tour is claimed")
            }
        }
    }

    func testTheScoreboardHasAnInningsPerColumn() throws {
        let lead = try XCTUnwrap(try page().lead)
        let board = CricketPageText.scoreboard(lead)
        XCTAssertEqual(board.headers, ["1ST INNS", "2ND INNS", "OVERS"])
        XCTAssertEqual(board.rows.count, 2)
        XCTAssertEqual(board.rows[0].prefix(2).map { $0 }, ["329", "294/5"])
        XCTAssertNotNil(board.rows[0][2], "the open innings' overs")
        XCTAssertNil(board.rows[1][1], "one innings: nothing in the second column")
    }
}
