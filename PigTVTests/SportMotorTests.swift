import XCTest
@testable import PigTV

// D-43 (Apple 99, part B, mock-ups V2-Motor-1 and V2-Motor-4): the Motorsport page's content. Formula 1 from the
// server's own answer (`f1-page-0346.json`): the five sessions as tiles, then the last race (or the grid) and both
// standings, ten each, the followed driver marked; spoiler-free hides all three. NASCAR (C-V `race`): the entry list in
// name order, the last winner (hidden when spoiler-free) and the next race. Before Apple 99 none of this existed: the
// Motorsport page embedded the old F1 page, and IndyCar and NASCAR showed C-R cards only.
final class SportMotorTests: XCTestCase {
    private func page() throws -> F1Page { try JSONDecoder().decode(F1Page.self, from: F1PageTextTests.fixture()) }

    func testTheWeekendsSessionsAreTilesInOrder() throws {
        let weekend = try XCTUnwrap(try page().weekend)
        let before = Date(timeIntervalSince1970: 1_793_380_000)
        let tiles = SportMotorText.tiles(weekend, now: before, spoilerFree: false)
        XCTAssertEqual(tiles.map(\.id), ["practice 1", "practice 2", "practice 3", "qualifying", "race"])
        XCTAssertEqual(tiles.map(\.state), [.next, .later, .later, .later, .later], "the first to come is next")
        let duringP1 = Date(timeIntervalSince1970: 1_793_385_000 + 600)
        XCTAssertEqual(SportMotorText.tiles(weekend, now: duringP1, spoilerFree: false).first?.state, .live)
        XCTAssertEqual(SportMotorText.tiles(weekend, now: duringP1, spoilerFree: false).first?.line, "On now")
    }

    func testTheThreeListsHaveTenRowsEachAndMarkTheFollowedDriver() throws {
        let lists = SportMotorText.lists(try page(), followed: ["Oscar Piastri"], spoilerFree: false)
        XCTAssertFalse(lists.hidden)
        XCTAssertEqual(lists.gridTitle, "Last race · United States GP")
        XCTAssertEqual(lists.grid.count, 10)
        XCTAssertEqual(lists.drivers.count, 10)
        XCTAssertEqual(lists.constructors.count, 10)
        XCTAssertEqual(lists.drivers.filter(\.followed).map(\.name), ["Oscar Piastri"])
        XCTAssertEqual(lists.drivers.first { $0.followed }?.points, "144")
        XCTAssertFalse(lists.constructors.contains(where: \.followed))
    }

    func testSpoilerFreeHidesTheGridAndStandings() throws {
        let lists = SportMotorText.lists(try page(), followed: ["Oscar Piastri"], spoilerFree: true)
        XCTAssertTrue(lists.hidden)
        XCTAssertTrue(lists.grid.isEmpty && lists.drivers.isEmpty && lists.constructors.isEmpty)
        let weekend = try XCTUnwrap(try page().weekend)
        let after = Date(timeIntervalSince1970: 1_793_600_000)
        XCTAssertTrue(SportMotorText.tiles(weekend, now: after, spoilerFree: true).allSatisfy { $0.line == "Finished" },
                      "no fastest, pole or winner")
    }

    func testTheFollowedDriversAreTheSportsNames() {
        XCTAssertEqual(SportMotorText.followedDrivers(SportPagePreferences(f1Following: "Oscar Piastri", teams: ["F1": ["Lando Norris"]])),
                       ["Lando Norris", "Oscar Piastri"])
    }

    func testNASCARShowsTheEntryListLastWinnerAndNextRace() throws {
        let page = try SportPagesFixture.events("NASCAR")
        let event = SportEventsText.focus(page.events)
        let race = SportEventsText.race(page, event: event, spoilerFree: false)
        XCTAssertEqual(race.entries, race.entries.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        XCTAssertEqual(race.entries.count, 18)
        XCTAssertEqual(race.lastWinner, "Kyle Larson")
        XCTAssertEqual(race.lastRace, "NASCAR Cup Series at Talladega")
        XCTAssertEqual(race.next?.name, "NASCAR Cup Series at Martinsville")
        XCTAssertNil(SportEventsText.race(page, event: event, spoilerFree: true).lastWinner, "spoiler-free: no winner")
    }

    func testMotoGPAndSupercarsCardsAreTilesBySoonest() throws {
        let front = try SportFrontLayoutTests.front()
        let tiles = SportMotorText.cardTiles(front.games.reversed())
        XCTAssertEqual(tiles.map(\.start), tiles.map(\.start).sorted())
        XCTAssertLessThanOrEqual(tiles.count, 6)
    }
}
