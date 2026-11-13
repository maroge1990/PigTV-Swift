import XCTest
@testable import PigTV

// maroge1990/PigTV#203 (D-42 point 5, Mark 1 Nov): while a game's coverage is on air and play starts within about 30
// minutes, it reads "On air · starts 3:10 pm" with the live dot and Watch, for every sport. The server marks it
// `onAir: true` (C-O/C-R cards and C-P sessions since 0423; `status` stays `scheduled`). Before the fix the Apple client
// never decoded `onAir`: such a game read "UPCOMING"/"NEXT" with its start time and no live dot (these tests fail to
// compile on the old code: `isOnAir`, `onAirLine` and `showsLive` did not exist).
@MainActor
final class SportOnAirTests: XCTestCase {
    static let chiefs = "espn:football/nfl:406" // scheduled, two-sided, on ESPN HD
    static let race = "espn:racing/f1:1" // scheduled F1 session "Race"; the follow Oscar Piastri's game

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The 0381 front answer with `onAir` set (or a raw value) on the games named.
    private func front(onAir value: Any? = true, games ids: [String] = [chiefs, race],
                       change: (inout [String: Any]) -> Void = { _ in }) throws -> SportFront {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: SportFrontTests.fixture()) as? [String: Any])
        var games = json["games"] as? [[String: Any]] ?? []
        for index in games.indices where ids.contains(games[index]["id"] as? String ?? "") {
            if let value { games[index]["onAir"] = value }
        }
        json["games"] = games
        change(&json)
        return try JSONDecoder().decode(SportFront.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func time(_ ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        return SportFrontText.when(date, now: date, calendar: Self.utc)
    }

    // MARK: Decode

    func testOnAirDecodesAndIsFalseWhenAbsentOrMalformed() throws {
        XCTAssertTrue(try XCTUnwrap(front().game(Self.chiefs)).isOnAir)
        XCTAssertFalse(try XCTUnwrap(front(onAir: nil).game(Self.chiefs)).isOnAir, "an older server: absent")
        XCTAssertFalse(try XCTUnwrap(front(onAir: false).game(Self.chiefs)).isOnAir)
        let malformed = try front(onAir: "yes")
        XCTAssertEqual(malformed.games.count, 6, "a malformed onAir never drops the card")
        XCTAssertFalse(try XCTUnwrap(malformed.game(Self.chiefs)).isOnAir)
        // Only a scheduled game is on air: once play starts it is live (and worded as live).
        XCTAssertFalse(try XCTUnwrap(front(games: [SportFrontTests.packers]).game(SportFrontTests.packers)).isOnAir)
    }

    // MARK: The words

    func testACardReadsOnAirStartsWithTheLiveDot() throws {
        let f = try front()
        let game = try XCTUnwrap(f.game(Self.chiefs))
        let words = "On air · starts \(time(game.start))"
        XCTAssertEqual(SportFrontText.onAirLine(game, calendar: Self.utc), words)
        XCTAssertFalse(words.contains("UPCOMING"))
        XCTAssertTrue(SportFrontText.showsLive(game), "the live dot")
        XCTAssertEqual(SportFrontText.cardClock(game, in: f, hidden: false), SportFrontText.onAirLine(game))
        XCTAssertEqual(game.statusLabel, "ON AIR", "never UPCOMING, never a result")
        XCTAssertEqual(SportFrontText.drawn(game, in: f, hidden: false).kicker, "ON AIR")
        // Without onAir the same game is upcoming, no dot.
        let plain = try XCTUnwrap(front(onAir: nil).game(Self.chiefs))
        XCTAssertFalse(SportFrontText.showsLive(plain))
        XCTAssertEqual(plain.statusLabel, "UPCOMING")
        XCTAssertEqual(SportFrontText.drawn(plain, in: f, hidden: false).kicker, "NEXT")
    }

    func testTheHeroBannerAndStripSayOnAir() throws {
        let f = try front()
        let game = try XCTUnwrap(f.game(Self.chiefs))
        let now = Date(timeIntervalSince1970: (game.start - 20 * 60_000) / 1000)
        let hero = SportFrontLayout.hero(game, in: f, hidden: false, now: now, calendar: Self.utc)
        XCTAssertTrue(hero.live, "the kicker's live dot")
        XCTAssertTrue(hero.kicker.hasPrefix("ON AIR · "), hero.kicker)
        XCTAssertEqual(hero.liveWord, "ON AIR")
        XCTAssertTrue(hero.line.contains("On air · starts \(time(game.start))"), hero.line)
        let strip = SportHeroStrip(hero: hero, items: [], selected: nil)
        XCTAssertTrue(strip.live)
        XCTAssertEqual(strip.liveWord, "ON AIR")
        // A live game keeps "LIVE".
        let live = try XCTUnwrap(f.game(SportFrontTests.packers))
        XCTAssertEqual(SportFrontLayout.hero(live, in: f, hidden: false, now: now).liveWord, "LIVE")
    }

    func testAFollowWhoseSessionIsOnAirReadsOnAirInTheBannersList() throws {
        // The server marks the follow live (C-R since 0423); the row words it as on air, with the session.
        let f = try front { json in
            var follows = json["follows"] as? [[String: Any]] ?? []
            follows[0]["state"] = "live"
            json["follows"] = follows
        }
        let game = try XCTUnwrap(f.game(Self.race))
        let now = Date(timeIntervalSince1970: (game.start - 20 * 60_000) / 1000)
        let item = try XCTUnwrap(SportFrontLayout.followItems(f, now: now, calendar: Self.utc).first)
        XCTAssertEqual(item.trailing, "Race · On air · starts \(time(game.start))")
        XCTAssertTrue(item.live)
    }

    func testThePhoneCardAndRowSayOnAir() throws {
        let f = try front()
        let game = try XCTUnwrap(f.game(Self.chiefs))
        let now = Date(timeIntervalSince1970: (game.start - 20 * 60_000) / 1000)
        let row = SportPhoneLayout.row(game, in: f, hidden: false, now: now, follows: [], calendar: Self.utc)
        XCTAssertEqual(row.live, SportFrontText.onAirLine(game), "the row's live dot and words")
        let card = SportPhoneLayout.card(game, in: f, hidden: false, now: now, index: -1, id: game.id, league: "NFL",
                                         follow: nil, follows: [], calendar: Self.utc)
        XCTAssertTrue(card.live)
        XCTAssertEqual(card.kicker, "ON AIR · NFL")
        XCTAssertTrue(card.line.hasPrefix("On air · starts \(time(game.start))"), card.line)
    }

    // MARK: F1 sessions (C-P)

    func testAnF1SessionOnAirIsATileWithTheLiveDotWordedOnAir() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: F1PageTextTests.fixture()) as? [String: Any])
        var weekend = try XCTUnwrap(json["weekend"] as? [String: Any])
        var sessions = try XCTUnwrap(weekend["sessions"] as? [[String: Any]])
        sessions[0]["onAir"] = true // practice 1
        sessions[1]["onAir"] = "yes" // malformed: not on air, the session still decodes
        weekend["sessions"] = sessions
        json["weekend"] = weekend
        let page = try JSONDecoder().decode(F1Page.self, from: JSONSerialization.data(withJSONObject: json))
        let w = try XCTUnwrap(page.weekend)
        XCTAssertEqual(w.sessions.map(\.onAir), [true, false, false, false, false])
        let p1 = w.sessions[0]
        let before = Date(timeIntervalSince1970: p1.startTime / 1000 - 20 * 60)
        let tile = try XCTUnwrap(SportMotorText.tiles(w, now: before, spoilerFree: false).first)
        XCTAssertEqual(tile.state, .live, "the live pill and outline")
        XCTAssertEqual(tile.liveWord, "ON AIR")
        XCTAssertEqual(tile.line, F1PageText.onAirLine(p1))
        XCTAssertTrue(tile.line?.hasPrefix("On air · starts ") == true)
        XCTAssertEqual(F1PageText.headline(w, now: before), "Practice 1 · \(F1PageText.onAirLine(p1))")
        // Once it starts it is live as before.
        let during = Date(timeIntervalSince1970: p1.startTime / 1000 + 60)
        XCTAssertEqual(SportMotorText.tiles(w, now: during, spoilerFree: false).first?.line, "On now")
        XCTAssertEqual(SportMotorText.tiles(w, now: during, spoilerFree: false).first?.liveWord, "LIVE")
    }
}
