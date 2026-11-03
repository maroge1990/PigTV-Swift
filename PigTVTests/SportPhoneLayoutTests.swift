import XCTest
@testable import PigTV

// D-44 (R5-Front-iPhone, Apple 139): the iPhone front page's words from C-R (`sport-front-0427.json`: Liverpool and
// Chelsea live, Piastri and Arsenal next, three follows with nothing in 72 hours; Football, Motorsport and Basketball
// with games). Before Apple 139 the iPhone drew the earlier tiles-and-hero-band page.
final class SportPhoneLayoutTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        return calendar
    }

    private func now(_ f: SportFront) -> Date { Date(timeIntervalSince1970: f.now / 1000) }

    func testTheCarouselIsTheFollowsInTheOrderSent() throws {
        let f = try SportFrontLayoutTests.front()
        let cards = SportPhoneLayout.cards(f, hidden: false, now: now(f), calendar: calendar)
        XCTAssertEqual(cards.map(\.index), Array(0..<7))
        XCTAssertEqual(cards.map(\.id), f.follows.map(\.key))
        let liverpool = cards[0]
        XCTAssertTrue(liverpool.live)
        XCTAssertEqual(liverpool.kicker, "LIVE · EPL")
        XCTAssertEqual(liverpool.score, "1–1")
        XCTAssertEqual(liverpool.sides.map(\.name), ["Liverpool", "Man City"])
        XCTAssertEqual(liverpool.sides.map(\.followed), [true, false], "the followed side starred")
        XCTAssertEqual(liverpool.sides[0].logo, "/api/logo/espn-liv", "the real logo (#205, #213)")
        XCTAssertEqual(liverpool.line, "67' · Optus Sport 1 HD")
        let piastri = cards[2]
        XCTAssertFalse(piastri.live)
        XCTAssertEqual(piastri.title, "Mexico City Grand Prix")
        XCTAssertTrue(piastri.kicker.hasPrefix("F1 · "), piastri.kicker)
        XCTAssertTrue(piastri.line.hasSuffix("Fox Sports 506 UHD"), piastri.line)
        let bulls = cards[4]
        XCTAssertNil(bulls.gameId)
        XCTAssertEqual(bulls.line, "Nothing in the next three days")
        XCTAssertEqual(SportPhoneLayout.position(0, of: 7), "1 of 7 follows")
    }

    /// #192: spoiler-free (the account's, or unknown) and the answer's own switch hide every score, and VoiceOver reads none.
    func testSpoilerFreeHidesEveryScoreAndItsWords() throws {
        let f = try SportFrontLayoutTests.front()
        for hiddenFront in [(f, true), (try SportFrontLayoutTests.front { $0["spoilerFree"] = true }, false)] {
            let (front, hidden) = hiddenFront
            let cards = SportPhoneLayout.cards(front, hidden: hidden, now: now(front), calendar: calendar)
            XCTAssertTrue(cards.allSatisfy { $0.score == nil })
            XCTAssertFalse(cards[0].accessibilityLabel.contains("1–1"), cards[0].accessibilityLabel)
            let rows = SportPhoneLayout.groups(front, hidden: hidden, now: now(front), calendar: calendar).flatMap(\.rows)
            XCTAssertFalse(rows.isEmpty)
            XCTAssertTrue(rows.allSatisfy { $0.score == nil })
            XCTAssertTrue(rows.allSatisfy { !$0.accessibilityLabel.contains("–") }, rows.map(\.accessibilityLabel).joined(separator: "\n"))
        }
        XCTAssertEqual(SportPhoneLayout.scoresChip(hidden: true), "Scores hidden")
        XCTAssertEqual(SportPhoneLayout.scoresChip(hidden: false), "Scores shown")
    }

    func testOneCardPerSportWithFixtureRows() throws {
        let f = try SportFrontLayoutTests.front()
        let groups = SportPhoneLayout.groups(f, hidden: false, now: now(f), calendar: calendar)
        XCTAssertEqual(groups.map(\.sport), ["Football", "Motorsport", "Basketball"])
        XCTAssertEqual(groups[0].note, "EPL, Champions League · 2 live")
        XCTAssertEqual(groups[0].rows.count, SportPhoneLayout.rowsPerSport, "the first games; the header opens the rest")
        let live = groups[0].rows[0]
        XCTAssertEqual(live.title, "Liverpool v Man City")
        XCTAssertEqual(live.score, "1–1")
        XCTAssertEqual(live.live, "LIVE 67'")
        XCTAssertEqual(live.sub, "Optus Sport 1 HD")
        XCTAssertEqual(live.sides.first?.logo, "/api/logo/espn-liv")
        XCTAssertTrue(live.accessibilityLabel.hasPrefix("Liverpool versus Man City"), live.accessibilityLabel)
        let race = groups[1].rows[0]
        XCTAssertTrue(race.sides.isEmpty)
        XCTAssertEqual(race.badge, "F1")
        XCTAssertTrue(race.sub.hasSuffix(" · Fox Sports 506 UHD"), race.sub)
        let nbl = try XCTUnwrap(groups[2].rows.first { $0.league == "NBL" })
        XCTAssertTrue(nbl.sub.hasSuffix(" · No TV listing found"), nbl.sub)
        XCTAssertEqual(SportPhoneLayout.badge("NASCAR Cup"), "NAS")
    }
}
