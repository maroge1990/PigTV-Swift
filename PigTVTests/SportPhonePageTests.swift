import XCTest
@testable import PigTV

// D-44 (R5-*-iPhone, #177, #186): a sport's page on the iPhone, from C-R (`sport-front-0427.json`: Liverpool and Chelsea
// live in the EPL, Arsenal v Tottenham finished, Man United v Aston Villa later today; Arsenal's Champions League game in
// two days; Basketball with nobody followed). Before Apple 142 the iPhone drew the Apple TV page squeezed to its width.
final class SportPhonePageTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        return calendar
    }

    private func now(_ f: SportFront) -> Date { Date(timeIntervalSince1970: f.now / 1000) }

    func testChipsAreTheSportsLeaguesOnlyWhenItHasSeveral() throws {
        let f = try SportFrontLayoutTests.front()
        XCTAssertEqual(SportPhonePageLayout.chips("Football", in: f), ["EPL", "Champions League"])
        XCTAssertEqual(SportPhonePageLayout.chips("Motorsport", in: f), [], "one league: no chips")
        XCTAssertEqual(SportPhonePageLayout.league("Football", chosen: nil, in: f), "EPL", "the hero's league first")
        XCTAssertEqual(SportPhonePageLayout.league("Football", chosen: "Champions League", in: f), "Champions League")
        XCTAssertEqual(SportPhonePageLayout.league("Football", chosen: "NBA", in: f), "EPL", "another sport's league is not kept")
    }

    /// The carousel: yours (each follow's card records its own team, #49), then the rest live; with neither, the next.
    func testTheCarouselIsYoursThenLiveElseTheNext() throws {
        let f = try SportFrontLayoutTests.front()
        let epl = SportPhonePageLayout.cards(league: "EPL", in: f, hidden: false, now: now(f), calendar: calendar)
        XCTAssertEqual(epl.map(\.gameId), ["espn:soccer/eng.1:1", "espn:soccer/eng.1:2"])
        XCTAssertEqual(epl.map(\.team), ["Liverpool", "Chelsea"])
        XCTAssertEqual(epl[0].kicker, "LIVE · EPL")
        XCTAssertEqual(epl[0].score, "1–1")
        let cl = SportPhonePageLayout.cards(league: "Champions League", in: f, hidden: false, now: now(f), calendar: calendar)
        XCTAssertEqual(cl.map(\.gameId), ["espn:soccer/uefa.champions:1"], "Arsenal's next game")
        let nba = SportPhonePageLayout.cards(league: "NBA", in: f, hidden: false, now: now(f), calendar: calendar)
        XCTAssertEqual(nba.map(\.gameId), ["espn:basketball/nba:2"], "nobody followed, nothing live: the next to start")
        XCTAssertEqual(nba[0].team, "", "no follow, so no team named")
        XCTAssertEqual(SportPhonePageLayout.position(0, of: 4), "1 of 4 · yours, then live")
    }

    func testGamesAreGroupedLiveLaterTodayComingUpEarlier() throws {
        let f = try SportFrontLayoutTests.front()
        let epl = SportPhonePageLayout.groups(league: "EPL", in: f, hidden: false, now: now(f), calendar: calendar)
        XCTAssertEqual(epl.map(\.title), ["Live", "Later today", "Earlier"])
        XCTAssertEqual(epl[0].rows.map(\.id), ["espn:soccer/eng.1:1", "espn:soccer/eng.1:2"])
        XCTAssertEqual(epl[1].rows.map(\.id), ["espn:soccer/eng.1:4"])
        XCTAssertEqual(epl[2].rows.map(\.id), ["espn:soccer/eng.1:3"])
        XCTAssertEqual(epl[0].rows[0].sides.map(\.followed), [true, false])
        let cl = SportPhonePageLayout.groups(league: "Champions League", in: f, hidden: false, now: now(f), calendar: calendar)
        XCTAssertEqual(cl.map(\.title), ["Coming up"])
        XCTAssertEqual(cl[0].rows.count, 2)
    }

    /// #192: spoiler-free hides every score on the page, in the carousel and the rows, and in what VoiceOver reads.
    func testSpoilerFreeHidesEveryScore() throws {
        let f = try SportFrontLayoutTests.front()
        let cards = SportPhonePageLayout.cards(league: "EPL", in: f, hidden: true, now: now(f), calendar: calendar)
        let rows = SportPhonePageLayout.groups(league: "EPL", in: f, hidden: true, now: now(f), calendar: calendar).flatMap(\.rows)
        XCTAssertTrue(cards.allSatisfy { $0.score == nil })
        XCTAssertTrue(rows.allSatisfy { $0.score == nil })
        let spoken = cards.map(\.accessibilityLabel) + rows.map(\.accessibilityLabel)
        XCTAssertFalse(spoken.contains { $0.range(of: #"\d+–\d+"#, options: .regularExpression) != nil }, spoken.joined(separator: " | "))
    }

    /// #177: each league's extra content is a page of its own behind a header named for it.
    func testTheExtraContentIsAPageOfItsOwn() {
        XCTAssertEqual(SportPhonePageLayout.moreTitle(.league, sport: "Australian football"), "Rounds and standings")
        XCTAssertEqual(SportPhonePageLayout.moreTitle(.nfl, sport: "American football"), "Rounds and standings")
        XCTAssertEqual(SportPhonePageLayout.moreTitle(.f1, sport: "Motorsport"), "Weekend and standings")
        XCTAssertEqual(SportPhonePageLayout.moreTitle(.cricket("WBBL"), sport: "Cricket"), "Scoreboard and tour")
        XCTAssertEqual(SportPhonePageLayout.moreTitle(.events, sport: "Golf"), "Leaderboard")
        XCTAssertEqual(SportPhonePageLayout.moreTitle(.events, sport: "Tennis"), "Order of play")
        XCTAssertEqual(SportPhonePageLayout.moreTitle(.events, sport: "Combat"), "Fight card")
        XCTAssertNil(SportPhonePageLayout.moreTitle(.games, sport: "Basketball"), "no page beyond its games")
    }
}
