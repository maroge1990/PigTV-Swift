import XCTest
@testable import PigTV

// D-43 (Apple 99, parts E and F): the C-V pages from `sport-pages-d43.json` (the server's golden answers, trimmed and
// extended). UFC (V2-UFC-1): the main card and the prelims as two lists, each finished bout with its winner, round and
// clock, hidden when spoiler-free. Tennis (V2-Tennis-4, V3-Tennis-4-none): the rails from the matches, Your players only
// when a followed player plays this week; set scores hidden when spoiler-free. Golf (V3-Golf-final, -none): the
// leaderboard's top 11, the followed players' cards with the gap to the lead, the none state, spoiler-free. Before
// Apple 99 there were no event pages: these leagues showed their C-R cards.
final class SportEventsTests: XCTestCase {
    private let now = SportPagesFixture.now
    private let utc = SportPagesFixture.utc

    func testTheServersGoldenShapesDecode() throws {
        for league in ["UFC", "WTA Tour", "PGA Tour", "NASCAR"] {
            let page = try SportPagesFixture.events(league)
            XCTAssertTrue(page.available, league)
            XCTAssertFalse(page.events.isEmpty, league)
        }
    }

    // MARK: UFC

    func testTheNightSplitsIntoTheMainCardAndThePrelims() throws {
        let page = try SportPagesFixture.events("UFC")
        let event = try XCTUnwrap(SportEventsText.focus(page.events))
        XCTAssertEqual(event.status, "live", "the night under way leads")
        let card = SportEventsText.card(event)
        XCTAssertEqual(card.main.count, 4)
        XCTAssertEqual(card.prelims.count, 3)
        XCTAssertEqual(card.main.last?.fighters.map(\.name), ["Renato Moicano", "Tom Nolan"], "the main event last")
    }

    func testAFinishedBoutSaysItsWinnerRoundAndClockUnlessSpoilerFree() throws {
        let event = try XCTUnwrap(SportEventsText.focus(try SportPagesFixture.events("UFC").events))
        let card = SportEventsText.card(event)
        let first = card.prelims[0]
        XCTAssertEqual(SportEventsText.boutLine(first, isMainEvent: false, spoilerFree: false), "Szabová · R3 3:20")
        XCTAssertEqual(SportEventsText.winner(first, spoilerFree: false), 1)
        XCTAssertEqual(SportEventsText.boutLine(first, isMainEvent: false, spoilerFree: true), "Finished")
        XCTAssertNil(SportEventsText.winner(first, spoilerFree: true))
        XCTAssertEqual(SportEventsText.boutLine(card.main[1], isMainEvent: false, spoilerFree: false), "Live")
        XCTAssertEqual(SportEventsText.boutLine(card.main[3], isMainEvent: true, spoilerFree: false), "Main event")
        XCTAssertEqual(SportEventsText.boutLine(card.main[2], isMainEvent: false, spoilerFree: false), "Up next")
        XCTAssertTrue(SportEventsText.followed("Lucia Szabová", in: event))
    }

    // MARK: Tennis

    func testTennisRailsWithAFollowedPlayer() throws {
        let page = try SportPagesFixture.events("WTA Tour")
        let rails = SportEventsText.rails(page.events, now: now, calendar: utc)
        XCTAssertEqual(rails.yourPlayers.map(\.id), ["185706"], "Claire Liu plays this week")
        XCTAssertEqual(Set(rails.liveNow.map(\.id)), ["185735", "187332"])
        XCTAssertTrue(rails.tonight.map(\.id).contains("187333"))
        XCTAssertFalse(rails.tonight.contains { $0.status != "scheduled" })
        XCTAssertEqual(rails.resultsToday.map(\.id), ["187324"])
    }

    func testNoYourPlayersRailWithoutAFollowedPlayerThisWeek() throws {
        let page = try SportPagesFixture.events("WTA Tour") { json in
            json["events"] = (json["events"] as? [[String: Any]] ?? []).map { var e = $0; e["followed"] = []; return e }
        }
        XCTAssertTrue(SportEventsText.rails(page.events, now: now, calendar: utc).yourPlayers.isEmpty)
    }

    func testSetScoresAreHiddenWhenSpoilerFree() throws {
        let page = try SportPagesFixture.events("WTA Tour")
        let final = try XCTUnwrap(page.events[0].matches.first { $0.id == "185735" })
        XCTAssertEqual(SportEventsText.sets(final, player: 0, spoilerFree: false), ["5"])
        XCTAssertEqual(SportEventsText.sets(final, player: 1, spoilerFree: false), ["4"])
        XCTAssertEqual(SportEventsText.sets(final, player: 0, spoilerFree: true), [])
        XCTAssertEqual(SportEventsText.playerName(final.players[0]), "Lilli Tagger [4]")
        XCTAssertEqual(SportEventsText.playerName(TennisMatch.Player(name: nil)), "TBD")
        let doubles = SportEventsEvent(id: "x", name: "x", start: 0, status: "live", followed: ["Maia Lumsden"])
        XCTAssertTrue(SportEventsText.followed("Mariia Kozyreva / Maia Lumsden", in: doubles), "either name of a pair")
    }

    // MARK: Golf

    func testGolfTopElevenAndTheFollowedPlayersCards() throws {
        let event = try XCTUnwrap(SportEventsText.focus(try SportPagesFixture.events("PGA Tour").events))
        let layout = SportEventsText.golf(event, spoilerFree: false)
        XCTAssertEqual(layout.leaderboard.count, 11)
        XCTAssertEqual(layout.leaderboard.first?.name, "Andrew Novak")
        XCTAssertEqual(layout.yourPlayers.map(\.name), ["Min Woo Lee", "Adam Scott"])
        XCTAssertEqual(layout.yourPlayers.map(\.gap), ["9 behind", "11 behind"])
        XCTAssertEqual(layout.yourPlayers[0].rounds, [67, 68, 67], "rounds 1–3")
        XCTAssertEqual(layout.yourPlayers[0].pos, "T6")
    }

    func testGolfWithNoFollowedPlayerHasNoCards() throws {
        let page = try SportPagesFixture.events("PGA Tour") { json in
            json["events"] = (json["events"] as? [[String: Any]] ?? []).map { var e = $0; e["followed"] = []; return e }
        }
        let event = try XCTUnwrap(SportEventsText.focus(page.events))
        XCTAssertTrue(SportEventsText.golf(event, spoilerFree: false).yourPlayers.isEmpty, "Also this week only")
        XCTAssertEqual(SportEventsText.golf(event, spoilerFree: false).leaderboard.count, 11)
    }

    func testGolfSpoilerFreeHidesTheLeaderboardAndScores() throws {
        let page = try SportPagesFixture.events("PGA Tour")
        let event = try XCTUnwrap(SportEventsText.focus(page.events))
        let layout = SportEventsText.golf(event, spoilerFree: true)
        XCTAssertTrue(layout.leaderboard.isEmpty)
        XCTAssertEqual(layout.yourPlayers.map(\.name), ["Min Woo Lee", "Adam Scott"], "the field stays")
        XCTAssertTrue(layout.yourPlayers.allSatisfy { $0.pos == nil && $0.toPar == nil && $0.rounds.isEmpty && $0.gap == nil })
        XCTAssertEqual(SportEventsText.alsoLine(event, now: now, spoilerFree: true), "Round 4 in play")
        XCTAssertEqual(SportEventsText.alsoLine(event, now: now, spoilerFree: false), "Novak -23")
    }

    func testToParReadsEvenAndATypographicMinus() {
        XCTAssertEqual(SportEventsText.par("E"), 0)
        XCTAssertEqual(SportEventsText.par("\u{2212}7"), -7)
        XCTAssertEqual(SportEventsText.par("+2"), 2)
        XCTAssertNil(SportEventsText.par(nil))
        XCTAssertEqual(SportEventsText.gap(GolfRow(pos: "1", name: "A", toPar: "-23"), leader: GolfRow(pos: "1", name: "A", toPar: "-23")), "Leader")
    }
}
