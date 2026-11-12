import XCTest
@testable import PigTV

// One definition of "a game is under way" (`SportStatus.underWay`): live, break and suspended. Before it, the league page
// counted only live and break, so a suspended game was polled at the slow 60 s rate there and the fast 30 s everywhere else.
@MainActor
final class SportStatusTests: XCTestCase {
    func testUnderWayStatuses() {
        for status in ["live", "break", "suspended"] { XCTAssertTrue(SportStatus.underWay(status), status) }
    }

    func testOtherStatusesAreNotUnderWay() {
        for status in ["scheduled", "done", "finished", "postponed", "cancelled", "", "unknown"] {
            XCTAssertFalse(SportStatus.underWay(status), status)
        }
    }

    func testTheFrontAndEventsSetsAreTheSameSet() {
        XCTAssertEqual(SportFrontHero.ongoing, SportStatus.underWayStatuses)
        XCTAssertEqual(SportEventsText.ongoing, SportStatus.underWayStatuses)
    }

    private func model(_ statuses: [String]) throws -> LeaguePageModel {
        let configuration = URLSessionConfiguration.ephemeral
        let model = LeaguePageModel(client: APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
                                                       session: URLSession(configuration: configuration)))
        let games = statuses.enumerated().map { index, status in
            LeagueGame(id: "g\(index)", start: 1_793_411_760_000, status: status,
                       home: .init(id: "h\(index)", abbr: "H\(index)"), away: .init(id: "a\(index)", abbr: "A\(index)"))
        }
        model.setFixture(LeaguePage(league: "AFL", rounds: [LeagueRound(key: "1", label: "Round 1", current: true, games: games)]), league: "AFL")
        return model
    }

    func testALeagueWithOnlyASuspendedGameKeepsTheFastRefresh() throws {
        let m = try model(["done", "suspended", "scheduled"])
        XCTAssertTrue(m.hasLiveGame("AFL"))
        XCTAssertEqual(m.pollInterval("AFL"), LeaguePageModel.liveRefreshInterval)
    }

    func testALeagueWithNothingUnderWayRefreshesSlowly() throws {
        let m = try model(["done", "scheduled", "postponed"])
        XCTAssertFalse(m.hasLiveGame("AFL"))
        XCTAssertEqual(m.pollInterval("AFL"), LeaguePageModel.refreshInterval)
    }

    func testLiveAndBreakKeepTheFastRefresh() throws {
        for status in ["live", "break"] {
            XCTAssertEqual(try model([status]).pollInterval("AFL"), LeaguePageModel.liveRefreshInterval, status)
        }
    }
}
