import XCTest
@testable import PigTV

// C-R (#21, D-39, Apple 89): the Sport front page. `sport-front-0381.json` is the server's own answer (server 0381's
// `/api/sports/front` over its fixtures: F1 next, one NFL game live (the followed Packers), one NBA game live, a guide
// cricket match, a finished Packers game; the Packers and Oscar Piastri followed; hero "follow-live" on the Packers).
// Before Apple 89 there is no front page: none of these types exist.
@MainActor
final class SportFrontTests: XCTestCase {
    static let packers = "espn:football/nfl:401"
    static let chiefs = "espn:football/nfl:406"
    static let nba = "espn:basketball/nba:1"
    static let race = "espn:racing/f1:1"

    nonisolated static func fixture() throws -> Data {
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            for url in bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [] {
                if url.lastPathComponent == "sport-front-0381.json" { return try Data(contentsOf: url) }
            }
        }
        throw XCTSkip("sport-front-0381.json is not in the test bundle")
    }

    /// The fixture, changed as JSON first.
    private func front(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> SportFront {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.fixture()) as? [String: Any])
        change(&json)
        return try JSONDecoder().decode(SportFront.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static func set(_ json: inout [String: Any], game id: String, status: String) {
        var games = json["games"] as? [[String: Any]] ?? []
        for index in games.indices where games[index]["id"] as? String == id { games[index]["status"] = status }
        json["games"] = games
    }

    private static func set(_ json: inout [String: Any], follow index: Int, state: String) {
        var follows = json["follows"] as? [[String: Any]] ?? []
        follows[index]["state"] = state
        json["follows"] = follows
    }

    private static func hero(_ json: inout [String: Any], _ reason: String, follow: Int?, game: String) {
        let hero: [String: Any] = ["reason": reason, "followIndex": follow.map { $0 as Any } ?? NSNull(), "gameId": game]
        json["hero"] = hero
    }

    private func model() throws -> SportFrontModel {
        SportFrontModel(client: APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture"))
    }

    func testTheServersAnswerDecodes() throws {
        let f = try front()
        XCTAssertEqual(f.games.count, 6)
        XCTAssertEqual(f.rails.count, 4)
        XCTAssertEqual(f.follows.count, 2)
        XCTAssertEqual(f.sports.map(\.league), ["F1", "NFL", "NBA", "Cricket"])
        XCTAssertEqual(f.hero.reason, "follow-live")
        XCTAssertEqual(f.hero.followIndex, 1)
        XCTAssertEqual(f.hero.gameId, Self.packers)
        XCTAssertEqual(f.follows[1].name, "Green Bay Packers")
        XCTAssertEqual(f.follows[1].cachedLogo, "/api/logo/espn-gb")
        XCTAssertNil(f.follows[0].cachedLogo, "drivers have no badge")
        XCTAssertEqual(f.games(in: f.rails[1]).map(\.id), [Self.packers, "espn:football/nfl:405", Self.chiefs])
        XCTAssertEqual(f.game(Self.packers)?.followed, true)
        XCTAssertEqual(f.game(Self.chiefs)?.channels.first?.startTime, 1793413062249, "each channel's own airing")
        XCTAssertFalse(f.scoresUnavailable)
        XCTAssertFalse(f.isEmpty)
    }

    func testTheHeroOpensOnTheServersChoice() throws {
        let m = try model()
        m.setFixture(try front())
        XCTAssertEqual(m.heroID, Self.packers)
        XCTAssertEqual(m.heroGame?.title, "Packers v Bears")
        XCTAssertEqual(m.heroFollowIndex, 1)
        XCTAssertEqual(m.interval, SportFrontModel.liveRefreshInterval, "20 s while a game is on")
    }

    func testTheHeroIsStickyUntilAFollowGoesLiveAndAPinWins() throws {
        let m = try model()
        // The Packers not yet on; the server's hero is the live NBA game.
        m.apply(try front { json in
            Self.set(&json, follow: 1, state: "next")
            Self.hero(&json, "league-live", follow: nil, game: Self.nba)
        })
        XCTAssertEqual(m.heroID, Self.nba)
        // Another live game appears and the server now proposes it: the hero stays while its game is on.
        m.apply(try front { json in
            Self.set(&json, follow: 1, state: "next")
            Self.set(&json, game: Self.chiefs, status: "live")
            Self.hero(&json, "league-live", follow: nil, game: Self.chiefs)
        })
        XCTAssertEqual(m.heroID, Self.nba, "a live hero stays when another live game appears")
        // A follow goes live: it takes the hero.
        m.apply(try front { json in
            Self.set(&json, game: Self.chiefs, status: "live")
            Self.hero(&json, "follow-live", follow: 1, game: Self.packers)
        })
        XCTAssertEqual(m.heroID, Self.packers, "a follow going live takes over")
        // A long press pins a card: it wins over the server and a follow going live.
        m.pin(Self.chiefs)
        XCTAssertEqual(m.heroID, Self.chiefs)
        m.apply(try front { json in
            Self.set(&json, follow: 0, state: "live")
            Self.set(&json, game: Self.race, status: "live")
            Self.set(&json, game: Self.chiefs, status: "live")
            Self.hero(&json, "follow-live", follow: 0, game: Self.race)
        })
        XCTAssertEqual(m.heroID, Self.chiefs, "pinned wins")
    }

    func testAHeroThatEndsGivesWayToTheServers() throws {
        let m = try model()
        m.apply(try front { json in Self.hero(&json, "league-live", follow: nil, game: Self.nba) })
        XCTAssertEqual(m.heroID, Self.nba)
        m.apply(try front { json in
            Self.set(&json, game: Self.nba, status: "finished")
            Self.hero(&json, "follow-live", follow: 1, game: Self.packers)
        })
        XCTAssertEqual(m.heroID, Self.packers)
    }

    func testSelectingAFollowFlipsTheHero() throws {
        let m = try model()
        m.setFixture(try front())
        m.select(follow: 0)
        XCTAssertEqual(m.heroID, Self.race)
        XCTAssertEqual(m.heroGame?.title, "Mexico City Grand Prix")
        XCTAssertEqual(m.heroFollowIndex, 0)
        m.apply(try front())
        XCTAssertEqual(m.heroID, Self.race, "the flip survives a refresh")
        m.select(follow: 1)
        XCTAssertEqual(m.heroID, Self.packers)
    }

    func testSpoilerFreeHidesScoresAndKeepsNeutralProgress() throws {
        let f = try front()
        let game = try XCTUnwrap(f.game(Self.packers))
        XCTAssertEqual(SportFrontText.scores(game, spoilerFree: false), ["7", "3"])
        XCTAssertNil(SportFrontText.scores(game, spoilerFree: true))
        XCTAssertEqual(SportFrontText.situation(game, spoilerFree: true), "Quarter 2 · 5:00")
        let final = try XCTUnwrap(f.game("espn:football/nfl:405"))
        XCTAssertNil(SportFrontText.scores(final, spoilerFree: true), "no result with spoiler-free on")
    }

    func testScoresUnavailableShowsTheBanner() throws {
        XCTAssertTrue(try front { $0["scores"] = "unavailable" }.scoresUnavailable)
        XCTAssertFalse(try front { $0["scores"] = "stale" }.scoresUnavailable)
    }

    func testNoFollowedSportIsTheEmptyState() throws {
        let f = try front { json in
            json["sports"] = []
            json["follows"] = []
            json["rails"] = []
            json["games"] = []
            Self.hero(&json, "none", follow: nil, game: "")
        }
        XCTAssertTrue(f.isEmpty)
        let m = try model()
        m.setFixture(f)
        XCTAssertNil(m.heroGame)
        XCTAssertEqual(m.interval, SportFrontModel.refreshInterval, "60 s with nothing on")
    }

    func testTheTilesWords() throws {
        let f = try front()
        let now = Date(timeIntervalSince1970: f.now / 1000)
        XCTAssertEqual(SportFrontText.tileLine(f.sports[1], in: f, now: now), "1 live")
        XCTAssertEqual(SportFrontText.tileLine(f.sports[3], in: f, now: now), "Nothing scheduled")
        let race = SportFrontText.tileLine(f.sports[0], in: f, now: now)
        XCTAssertFalse(race.isEmpty || race == "Nothing scheduled" || race.hasSuffix("live"), race)
        let live = try front { json in
            var sports = json["sports"] as? [[String: Any]] ?? []
            sports[0]["live"] = 1
            sports[0]["line"] = "live"
            json["sports"] = sports
            Self.set(&json, game: Self.race, status: "live")
        }
        XCTAssertEqual(SportFrontText.tileLine(live.sports[0], in: live, now: now), "Race live")
        XCTAssertEqual(SportFrontText.followLine(f.follows[1], in: f, now: now), "Live · Packers v Bears")
        XCTAssertEqual(SportFrontText.monogram("Green Bay Packers"), "GP")
        XCTAssertEqual(SportFrontText.monogram("Bears"), "B")
    }

    // Build 89 review: a badge whose logo failed (the fixture's Packers) drew an empty disc.
    func testABadgeFallsBackToTheMonogram() {
        XCTAssertFalse(SportFrontText.badgeShowsLogo(logo: nil, decoded: false), "no logo")
        XCTAssertFalse(SportFrontText.badgeShowsLogo(logo: "/api/logo/espn-gb", decoded: false), "loading or failed")
        XCTAssertTrue(SportFrontText.badgeShowsLogo(logo: "/api/logo/espn-gb", decoded: true))
    }

    func testCompactFollowsPutLiveFirstThenSoonest() throws {
        let f = try front()
        XCTAssertEqual(SportFrontText.compactOrder(f.follows), [1, 0])
        // A next game without a start goes after those with one; nothing scheduled last.
        let more = try front { json in
            var follows = json["follows"] as? [[String: Any]] ?? []
            follows.append(["league": "NBA", "name": "Lakers", "logo": NSNull(), "state": "next", "gameId": NSNull(), "start": NSNull()])
            follows.append(["league": "AFL", "name": "Collingwood", "logo": NSNull(), "state": "none", "gameId": NSNull(), "start": NSNull()])
            follows.append(["league": "NFL", "name": "Chicago Bears", "logo": NSNull(), "state": "next", "gameId": Self.chiefs, "start": 1793413362249.0])
            follows.insert(["league": "NBA", "name": "Celtics", "logo": NSNull(), "state": "next", "gameId": NSNull(), "start": NSNull()], at: 0)
            json["follows"] = follows
        }
        XCTAssertEqual(more.follows.map(\.name), ["Celtics", "Oscar Piastri", "Green Bay Packers", "Lakers", "Collingwood", "Chicago Bears"])
        XCTAssertEqual(SportFrontText.compactOrder(more.follows), [2, 5, 1, 0, 3, 4])
        let now = Date(timeIntervalSince1970: f.now / 1000)
        XCTAssertEqual(SportFrontText.followLine(more.follows[4], in: more, now: now), "Nothing in the next three days")
        XCTAssertEqual(SportFrontText.shortWhen(more.follows[4], now: now), "—")
    }

    func testANewlyLiveFollowClearsAFlip() throws {
        let m = try model()
        m.apply(try front { json in
            Self.set(&json, follow: 1, state: "next")
            Self.hero(&json, "league-live", follow: nil, game: Self.nba)
        })
        m.select(follow: 0)
        XCTAssertEqual(m.selectedFollow, 0)
        XCTAssertEqual(m.heroID, Self.race)
        m.apply(try front())
        XCTAssertNil(m.selectedFollow, "the Packers went live: the flip is cleared")
        XCTAssertEqual(m.heroID, Self.packers)
    }

    func testAFlipSurvivesTheListBeingReordered() throws {
        let m = try model()
        m.setFixture(try front())
        m.select(follow: 0)
        m.apply(try front { json in
            json["follows"] = Array((json["follows"] as? [[String: Any]] ?? []).reversed())
            Self.hero(&json, "follow-live", follow: 0, game: Self.packers)
        })
        XCTAssertEqual(m.selectedFollow, 1, "Oscar Piastri, now second")
        XCTAssertEqual(m.heroID, Self.race)
        XCTAssertEqual(m.heroFollowIndex, 1)
        m.apply(try front { json in json["follows"] = [(json["follows"] as? [[String: Any]] ?? [])[1]] })
        XCTAssertNil(m.selectedFollow, "unfollowed: the flip is let go")
        XCTAssertEqual(m.heroID, Self.packers)
    }

    func testAFinishedPinOrFlipLetsGo() throws {
        let m = try model()
        m.setFixture(try front())
        m.pin(Self.nba)
        XCTAssertEqual(m.heroID, Self.nba)
        m.apply(try front { json in Self.set(&json, game: Self.nba, status: "finished") })
        XCTAssertNil(m.pinned)
        XCTAssertEqual(m.heroID, Self.packers)
        m.select(follow: 1)
        XCTAssertEqual(m.selectedFollow, 1)
        m.apply(try front { json in
            Self.set(&json, game: Self.packers, status: "finished")
            Self.set(&json, follow: 1, state: "none")
            Self.hero(&json, "follow-next", follow: 0, game: Self.race)
        })
        XCTAssertNil(m.selectedFollow, "the flipped game ended")
        XCTAssertEqual(m.heroID, Self.race)
    }

    // What the hero band and a card draw, from the same `drawn` the view uses.
    func testSpoilerFreeHidesTheDrawnScores() throws {
        let m = try model()
        m.setFixture(try front())
        let f = try XCTUnwrap(m.front)
        let hero = try XCTUnwrap(m.heroGame)
        XCTAssertEqual(SportFrontText.drawn(hero, in: f, hidden: false).scores, ["7", "3"])
        let hidden = SportFrontText.drawn(hero, in: f, hidden: true)
        XCTAssertNil(hidden.scores, "the preference read on this device hides the hero's score")
        XCTAssertEqual(hidden.situation, "Quarter 2 · 5:00", "neutral progress stays")
        // The answer's own switch hides them too, even if a card still carried a score.
        let spoilerFree = try front { $0["spoilerFree"] = true }
        let card = try XCTUnwrap(spoilerFree.game(Self.packers))
        XCTAssertNil(SportFrontText.drawn(card, in: spoilerFree, hidden: false).scores)
        let final = try XCTUnwrap(spoilerFree.game("espn:football/nfl:405"))
        XCTAssertNil(SportFrontText.drawn(final, in: spoilerFree, hidden: false).scores, "no result")
    }

    func testWithoutTheScoresFeedACardDrawsNoClockOrScore() throws {
        let f = try front { $0["scores"] = "unavailable" }
        let cricket = SportFrontText.drawn(try XCTUnwrap(f.game("guide:ev-cricket")), in: f, hidden: false)
        XCTAssertNil(cricket.scores)
        XCTAssertNil(cricket.situation)
        XCTAssertEqual(cricket.kicker, "ON TV")
        XCTAssertEqual(cricket.status, "ON TV NOW")
        let packers = SportFrontText.drawn(try XCTUnwrap(f.game(Self.packers)), in: f, hidden: false)
        XCTAssertNil(packers.scores, "no score without the feed")
        XCTAssertNil(packers.situation, "no clock without the feed")
    }

    func testCardActions() throws {
        let f = try front()
        let now = Date(timeIntervalSince1970: f.now / 1000)
        XCTAssertEqual(SportFrontText.action(try XCTUnwrap(f.game("guide:ev-cricket")), now: now), .watch, "on a channel now")
        XCTAssertEqual(SportFrontText.action(try XCTUnwrap(f.game(Self.chiefs)), now: now), .remind)
        XCTAssertEqual(SportFrontText.action(try XCTUnwrap(f.game(Self.packers)), now: now), .none, "no channel")
        let event = try XCTUnwrap(SportFrontText.event(try XCTUnwrap(f.game(Self.chiefs))))
        XCTAssertEqual(event.startTime, 1793413062249, "the channel's own airing (#20)")
        XCTAssertEqual(event.endTime, 1793424762249)
    }

    // Codex round 1 (HIGH): a cached live card stayed watchable after its channel's airing ended, so Watch tuned the
    // channel after the game. Watch now needs the channel to air it at the clock of the press; `canWatch` never
    // outlasts the channel's own end.
    static let cricket = "guide:ev-cricket"
    static let cricketEnd = 1793428062249.0

    func testACachedWatchableCardIsNotWatchableAfterItsChannelsAiringEnds() throws {
        let game = try XCTUnwrap(try front().game(Self.cricket))
        XCTAssertTrue(game.canWatch, "the answer said it could be watched")
        let later = SportFrontText.date(Self.cricketEnd + 60_000)
        XCTAssertNotEqual(SportFrontText.action(game, now: later), .watch)
        XCTAssertNil(SportFrontText.playable(game, at: later))
        XCTAssertEqual(SportFrontText.action(game, now: later), .details, "Record and the channels instead")
    }

    func testAfterAFailedRefreshTheOldLiveCardIsNotWatchableOnceItsAiringEnds() async throws {
        FrontRoutes.asked = []
        FrontRoutes.status = 200
        defer { FrontRoutes.status = 200 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FrontRoutes.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
                               session: URLSession(configuration: configuration))
        let m = SportFrontModel(client: client)
        await m.load()
        XCTAssertFalse(m.stale)
        FrontRoutes.status = 500
        await m.load()
        XCTAssertTrue(m.stale, "the answer shown is an old one")
        XCTAssertNotNil(m.updatedAt)
        let kept = try XCTUnwrap(m.front?.game(Self.cricket), "a failed refresh keeps the previous answer")
        let later = SportFrontText.date(Self.cricketEnd + 1000)
        XCTAssertNotEqual(SportFrontText.action(kept, now: later), .watch)
        XCTAssertNil(SportFrontText.playable(kept, at: later))
        FrontRoutes.status = 200
        await m.load()
        XCTAssertFalse(m.stale)
    }

    func testACardOnAChannelAiringNowIsStillWatchable() throws {
        let f = try front()
        let game = try XCTUnwrap(f.game(Self.cricket))
        let now = SportFrontText.date(f.now)
        XCTAssertEqual(SportFrontText.action(game, now: now), .watch)
        let event = try XCTUnwrap(SportFrontText.playable(game, at: now))
        XCTAssertEqual(event.best?.name, "Fox Cricket")
        XCTAssertEqual(SportFrontText.action(game, now: SportFrontText.date(Self.cricketEnd - 1000)), .watch, "until its end")
    }

    // Codex round 2 (HIGH): an expired card opens the event page, whose Watch and channel rows played any channel whose
    // airing had started, even after it ended (`playsChannelNow` had no end), tuning what followed the game.
    func testAnExpiredCardsEventPageOffersNoWatch() throws {
        let event = try XCTUnwrap(SportFrontText.event(try XCTUnwrap(try front().game(Self.cricket))))
        let later = SportFrontText.date(Self.cricketEnd + 60_000)
        XCTAssertFalse(SportRows.playsChannelNow(event, now: later), "the page's primary Watch")
        XCTAssertEqual(SportRows.channelAction(event, now: later), .ended, "Not on now")
        XCTAssertFalse(SportRows.playsChannelNow(event, on: event.channels[0], now: later), "its channel row")
    }

    func testAChannelRowWithAPastEndIsNotWatchable() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ms = now.timeIntervalSince1970 * 1000
        let ended = SportEventChannel(sourceId: 1, rawID: "a", name: "Early", startTime: ms - 3 * 3_600_000, endTime: ms - 600_000)
        let airing = SportEventChannel(sourceId: 1, rawID: "b", name: "Late", startTime: ms - 3_600_000, endTime: ms + 3_600_000)
        let event = SportEvent(id: "e", title: "A v B", league: "NFL", startTime: ms - 3 * 3_600_000, endTime: ms + 3_600_000,
                               channels: [ended, airing])
        XCTAssertFalse(SportRows.playsChannelNow(event, on: ended, now: now), "its airing ended ten minutes ago")
        XCTAssertEqual(SportRows.channelAction(event, on: ended, now: now), .ended)
        XCTAssertTrue(SportRows.playsChannelNow(event, on: airing, now: now), "the other channel is still on")
        XCTAssertEqual(SportRows.channelAction(event, on: airing, now: now), .play)
    }

    func testAChannelAiringNowIsStillWatchableOnTheEventPage() throws {
        let f = try front()
        let event = try XCTUnwrap(SportFrontText.event(try XCTUnwrap(f.game(Self.cricket))))
        XCTAssertTrue(SportRows.playsChannelNow(event, now: SportFrontText.date(f.now)))
        XCTAssertTrue(SportRows.playsChannelNow(event, now: SportFrontText.date(Self.cricketEnd - 1000)), "until its end")
    }

    // D-39: the app opens on Sport when the server has it, Sport first and TV second; Home is "TV" with the tag "home".
    func testTheAppOpensOnSport() {
        XCTAssertEqual(LibraryView.openingTab(sportEnabled: true), "sport")
        XCTAssertEqual(LibraryView.openingTab(sportEnabled: false), "home")
        XCTAssertEqual(LibraryView.tabOrder(sportEnabled: true), ["sport", "home", "guide", "recordings", "settings"])
        XCTAssertEqual(LibraryView.tabOrder(sportEnabled: false), ["home", "guide", "recordings", "settings"])
    }

    func testItLoadsTheFrontRoute() async throws {
        FrontRoutes.asked = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FrontRoutes.self]
        let client = APIClient(address: try ServerAddress("https://fixture.invalid"), token: "fixture",
                               session: URLSession(configuration: configuration))
        let m = SportFrontModel(client: client)
        await m.load()
        XCTAssertEqual(FrontRoutes.asked, ["/api/sports/front"])
        XCTAssertEqual(m.heroID, Self.packers)
        XCTAssertNil(m.error)
    }
}

private final class FrontRoutes: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var asked: [String] = []
    nonisolated(unsafe) static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.asked.append(path)
        let body = path.hasSuffix("sports/front") ? ((try? SportFrontTests.fixture()) ?? Data("{}".utf8)) : Data("{}".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.status == 200 ? body : Data(#"{"error":"down"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
