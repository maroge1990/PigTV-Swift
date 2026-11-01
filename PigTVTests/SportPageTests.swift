import XCTest
@testable import PigTV

// D-43 (1 Nov): a sport page's banner and what shows below it, from C-R (`sport-front-0427.json`: Football with the
// followed Liverpool live, Motorsport with F1 only and Piastri next, Basketball with nothing for the account, Tennis with
// nothing in 72 hours). Before Apple 97 there are no sport pages: none of these types exist.
final class SportPageTests: XCTestCase {
    private func front(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> SportFront {
        try SportFrontLayoutTests.front(change)
    }

    private static func set(_ json: inout [String: Any], follow name: String, state: String) {
        var follows = json["follows"] as? [[String: Any]] ?? []
        for index in follows.indices where follows[index]["name"] as? String == name { follows[index]["state"] = state }
        json["follows"] = follows
    }

    private static func set(_ json: inout [String: Any], game id: String, status: String) {
        var games = json["games"] as? [[String: Any]] ?? []
        for index in games.indices where games[index]["id"] as? String == id { games[index]["status"] = status }
        json["games"] = games
    }

    func testTheListIsTheSportsLeaguesInTheOrderSent() throws {
        let f = try front()
        XCTAssertEqual(SportPageRules.leagues("Football", in: f).map(\.league), ["EPL", "Champions League"])
        XCTAssertEqual(SportPageRules.leagues("Basketball", in: f).map(\.league), ["NBA", "NBL"])
        XCTAssertEqual(SportPageRules.leagues("Motorsport", in: f).map(\.league), ["F1"])
        XCTAssertTrue(SportBannerLayout.fullWidth(itemCount: SportPageRules.leagues("Motorsport", in: f).count),
                      "one league: a full-width banner")
        XCTAssertFalse(SportBannerLayout.fullWidth(itemCount: SportPageRules.leagues("Football", in: f).count))
        // The server moved a league with a game on to the top: kept as sent.
        let moved = try front { json in
            var sports = json["sports"] as? [[String: Any]] ?? []
            sports.swapAt(3, 4)
            json["sports"] = sports
        }
        XCTAssertEqual(SportPageRules.leagues("Basketball", in: moved).map(\.league), ["NBL", "NBA"])
        let now = Date(timeIntervalSince1970: f.now / 1000)
        let items = SportPageRules.leagueItems("Football", in: f, now: now)
        XCTAssertEqual(items.map(\.trailing).first, "2 live")
        XCTAssertTrue(items[0].live)
        XCTAssertEqual(SportPageRules.leagueItems("Tennis", in: f, now: now).map(\.trailing), ["Nothing scheduled"])
        // An older server: no `sport`, the league is its own sport.
        let old = try JSONDecoder().decode(SportFront.self, from: SportFrontTests.fixture())
        XCTAssertEqual(SportPageRules.leagues("Cricket", in: old).map(\.league), ["Cricket"])
    }

    func testTheHeroIsAFollowLiveThenTheLeagueLiveThenAFollowNextThenTheLeaguesNext() throws {
        // A follow live.
        let f = try front()
        XCTAssertEqual(SportPageRules.hero("Football", in: f), .init(gameId: "espn:soccer/eng.1:1", reason: .followLive, followIndex: 0))
        // No follow live, a league game live: that game.
        let leagueLive = try front { json in
            Self.set(&json, follow: "Liverpool", state: "next")
            Self.set(&json, follow: "Chelsea", state: "next")
        }
        XCTAssertEqual(SportPageRules.hero("Football", in: leagueLive).reason, .leagueLive)
        XCTAssertEqual(SportPageRules.hero("Football", in: leagueLive).gameId, "espn:soccer/eng.1:1", "the first live game in the rails' order")
        // Nothing live: the soonest next game of a follow.
        let followNext = try front { json in
            for id in ["espn:soccer/eng.1:1", "espn:soccer/eng.1:2"] { Self.set(&json, game: id, status: "finished") }
            Self.set(&json, follow: "Liverpool", state: "none")
            Self.set(&json, follow: "Chelsea", state: "none")
        }
        XCTAssertEqual(SportPageRules.hero("Football", in: followNext),
                       .init(gameId: "espn:soccer/uefa.champions:1", reason: .followNext, followIndex: 3))
        XCTAssertEqual(SportPageRules.hero("Motorsport", in: f), .init(gameId: "espn:racing/f1:1", reason: .followNext, followIndex: 2))
        // Nothing live or next for you: the league's next game (Remind me), never an empty banner.
        let quiet = SportPageRules.hero("Basketball", in: f)
        XCTAssertEqual(quiet, .init(gameId: "espn:basketball/nba:2", reason: .leagueNext), "the soonest scheduled game")
        XCTAssertEqual(SportFrontText.action(try XCTUnwrap(f.game(quiet.gameId)), now: Date(timeIntervalSince1970: f.now / 1000)), .remind)
        // Nothing at all in the next 72 hours: the sport's own quiet words.
        XCTAssertEqual(SportPageRules.hero("Tennis", in: f).reason, .none)
        XCTAssertEqual(SportPageRules.quietHero("Tennis").line, "Nothing in the next three days")
    }

    func testTheServersOwnLivePickWinsInsideTheSport() throws {
        let f = try front { json in json["hero"] = ["reason": "follow-live", "followIndex": 1, "gameId": "espn:soccer/eng.1:2"] }
        XCTAssertEqual(SportPageRules.hero("Football", in: f).gameId, "espn:soccer/eng.1:2", "the one closest to finishing")
    }

    func testThePageOpensOnTheHerosLeagueAndShowsItsContent() throws {
        let f = try front()
        XCTAssertEqual(SportPageRules.openingLeague("Football", in: f, hero: SportPageRules.hero("Football", in: f)), "EPL")
        let arsenal = try front { json in
            for id in ["espn:soccer/eng.1:1", "espn:soccer/eng.1:2"] { Self.set(&json, game: id, status: "finished") }
            Self.set(&json, follow: "Liverpool", state: "none")
            Self.set(&json, follow: "Chelsea", state: "none")
        }
        XCTAssertEqual(SportPageRules.openingLeague("Football", in: arsenal, hero: SportPageRules.hero("Football", in: arsenal)),
                       "Champions League")
        XCTAssertEqual(SportPageRules.openingLeague("Tennis", in: f, hero: SportPageRules.hero("Tennis", in: f)), "ATP Tour")
        XCTAssertEqual(SportPageRules.games(league: "Champions League", in: f).map(\.id),
                       ["espn:soccer/uefa.champions:1", "espn:soccer/uefa.champions:2"])
        XCTAssertEqual(SportPageRules.content(league: "F1", sport: "Motorsport", f1: true, nfl: true, cricket: true), .f1)
        XCTAssertEqual(SportPageRules.content(league: "F1", sport: "Motorsport", f1: false, nfl: true, cricket: true), .games)
        XCTAssertEqual(SportPageRules.content(league: "NFL", sport: "American football", f1: true, nfl: true, cricket: true), .nfl)
        XCTAssertEqual(SportPageRules.content(league: "BBL", sport: "Cricket", f1: true, nfl: true, cricket: true), .cricket("BBL"))
        XCTAssertEqual(SportPageRules.content(league: "EPL", sport: "Football", f1: true, nfl: true, cricket: true), .games)
    }
}
