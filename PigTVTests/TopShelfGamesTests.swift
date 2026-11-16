import XCTest
@testable import PigTV

/// #232 (D-66): the Top Shelf carousel of live games. The games come from the Sport front page's answer (followed
/// teams' games first, then the other live games of the followed leagues, at most ten); scores follow the account's Hide
/// scores (unknown hides), and a game anyone in the household is recording shows "Recording" in place of its score;
/// switching scores off clears the saved Top Shelf at once.
@MainActor
final class TopShelfGamesTests: XCTestCase {
    private static let now = Date()
    private static let ms = now.timeIntervalSince1970 * 1000

    private static func channel(_ id: String, _ name: String, number: Int? = nil) -> [String: Any] {
        var channel: [String: Any] = ["sourceId": 1, "id": id, "name": name]
        if let number { channel["number"] = number }
        return channel
    }

    private static func game(_ id: String, league: String = "NFL", status: String = "live", followed: Bool = false,
                             competitors: [[String: Any]]? = nil, scores: [String]? = ["21", "17"],
                             channels: [[String: Any]]? = nil, recording: [String: Any]? = nil,
                             onAir: Bool? = nil, progress: [String: Any] = ["clock": "2:14", "period": 4]) -> [String: Any] {
        var game: [String: Any] = [
            "id": id, "league": league, "title": "Game \(id)", "start": ms - 600_000, "status": status,
            "freshness": "fresh", "progress": progress,
            "availability": "matched", "broadcastStatus": "on-tv",
            "channels": channels ?? [channel("ch-\(id)", "Channel \(id)", number: 503)], "events": [], "canWatch": true,
            "competitors": competitors ?? [["id": "1", "name": "Green Bay Packers", "logo": "/api/logo/gb", "abbreviation": "GB"],
                                           ["id": "2", "name": "Chicago Bears"]],
            "followed": followed,
        ]
        if let scores { game["scores"] = scores }
        if let recording { game["recording"] = recording }
        if let onAir { game["onAir"] = onAir }
        return game
    }

    private static func front(_ games: [[String: Any]], spoilerFree: Bool = false, scores: String = "fresh") throws -> SportFront {
        let json: [String: Any] = ["now": ms, "spoilerFree": spoilerFree, "scores": scores,
                                   "sports": [["league": "NFL", "live": 1, "line": "live"]], "follows": [],
                                   "rails": [], "games": games]
        return try JSONDecoder().decode(SportFront.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func games(_ front: SportFront, hidden: Bool = false, answeredAt: Date = now,
                       labels: [String: String] = [:]) -> [TopShelfSnapshot.Game] {
        TopShelfGames.games(front, answeredAt: answeredAt, hidden: hidden, labels: labels, now: Self.now) ?? []
    }

    private func temporaryContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("topshelf-games-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Which games, in which order

    func testFollowedGamesComeFirstThenTheOtherLiveGamesAndOnlyLiveOnes() throws {
        let front = try Self.front([
            Self.game("a"), Self.game("b", followed: true), Self.game("later", status: "scheduled"),
            Self.game("done", status: "finished"), Self.game("c", status: "break"),
            Self.game("d", status: "suspended", followed: true), Self.game("onair", status: "scheduled", onAir: true),
        ])
        XCTAssertEqual(games(front).map(\.id), ["b", "d", "a", "c", "onair"])
    }

    func testAtMostTenGames() throws {
        let front = try Self.front((0..<14).map { Self.game("g\($0)", followed: $0 >= 10) })
        let ids = games(front).map(\.id)
        XCTAssertEqual(ids.count, TopShelfSnapshot.gameLimit)
        XCTAssertEqual(TopShelfSnapshot.gameLimit, 10)
        XCTAssertEqual(Array(ids.prefix(4)), ["g10", "g11", "g12", "g13"], "followed first, even past the cap")
    }

    func testNothingLiveOrNoRecentAnswerGivesNoGames() throws {
        let quiet = try Self.front([Self.game("later", status: "scheduled"), Self.game("done", status: "finished")])
        XCTAssertNil(TopShelfGames.games(quiet, answeredAt: Self.now, hidden: false, now: Self.now), "nothing live")
        let live = try Self.front([Self.game("g")])
        XCTAssertNil(TopShelfGames.games(nil, answeredAt: Self.now, hidden: false, now: Self.now), "no answer")
        XCTAssertNil(TopShelfGames.games(live, answeredAt: nil, hidden: false, now: Self.now), "an answer of unknown age")
        XCTAssertNil(TopShelfGames.games(live, answeredAt: Self.now.addingTimeInterval(-TopShelfSnapshot.gamesMaxAge - 1),
                                         hidden: false, now: Self.now), "an answer too old to show")
        XCTAssertNotNil(TopShelfGames.games(live, answeredAt: Self.now.addingTimeInterval(-60), hidden: false, now: Self.now))
    }

    // MARK: What each slide says

    func testASlideHasBothTeamsTheLeagueTheClockAndItsPlayChannel() throws {
        let game = try XCTUnwrap(games(try Self.front([Self.game("g")]), labels: ["NFL": "National Football League"]).first)
        XCTAssertEqual(game.sides?.map(\.name), ["Green Bay Packers", "Chicago Bears"])
        XCTAssertEqual(game.sides?.map(\.code), ["GB", "CHI"])
        XCTAssertEqual(game.sides?.map(\.logo), ["/api/logo/gb", nil])
        XCTAssertEqual(game.league, "National Football League")
        XCTAssertEqual(game.clock, "Q4 2:14", "SportFrontText.cardClock")
        XCTAssertEqual(game.scores, ["21", "17"])
        XCTAssertEqual(game.headline, "Green Bay Packers 21 – 17 Chicago Bears")
        XCTAssertEqual(game.context, "National Football League · Q4 2:14")
        XCTAssertEqual(PigTVLink.parse(game.playURL), PigTVLink.Play(sourceId: 1, id: "ch-g", name: "Channel g", number: 503),
                       "Play plays the game's best channel")
        XCTAssertEqual(PigTVLink.parseGame(game.gameURL), "g")
    }

    func testTheBestChannelIsTheFirst() throws {
        let front = try Self.front([Self.game("g", channels: [Self.channel("best", "Best HD"), Self.channel("other", "Other")])])
        let game = try XCTUnwrap(games(front).first)
        XCTAssertEqual(PigTVLink.parse(game.playURL)?.id, "best")
    }

    func testOnAirBeforePlaySaysWhenItStarts() throws {
        let game = try XCTUnwrap(games(try Self.front([Self.game("g", status: "scheduled", onAir: true)])).first)
        XCTAssertTrue(game.clock.hasPrefix("On air · starts "), game.clock)
    }

    func testARaceShowsItsTitle() throws {
        let game = try XCTUnwrap(games(try Self.front([Self.game("f1", league: "F1", competitors: [], scores: nil)])).first)
        XCTAssertNil(game.sides)
        XCTAssertNil(game.scores)
        XCTAssertEqual(game.headline, "Game f1")
    }

    // MARK: Scores (D-66)

    func testHideScoresHidesThem() throws {
        let hidden = try XCTUnwrap(games(try Self.front([Self.game("g")]), hidden: true).first)
        XCTAssertNil(hidden.scores)
        XCTAssertEqual(hidden.headline, "Green Bay Packers v Chicago Bears")
        XCTAssertEqual(hidden.context, "NFL · Q4 2:14", "where the game is up to still shows")
        let answer = try XCTUnwrap(games(try Self.front([Self.game("g")], spoilerFree: true)).first)
        XCTAssertNil(answer.scores, "the answer's own switch hides too")
        let noFeed = try XCTUnwrap(games(try Self.front([Self.game("g")], scores: "unavailable")).first)
        XCTAssertNil(noFeed.scores, "without the scores feed")
    }

    /// The account's choice unknown (not read yet, or being read again) counts as hidden.
    func testAnUnknownChoiceHidesScores() throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let browse = BrowseModel(client: try server.client())
        XCTAssertTrue(browse.f1Page.hidesSpoilers, "control: the choice is not known yet")
        browse.sportFront.setFixture(try Self.front([Self.game("g")]), answeredAt: Self.now)
        let game = try XCTUnwrap(browse.topShelfGames(now: Self.now)?.first)
        XCTAssertNil(game.scores)
    }

    func testAGameBeingRecordedShowsRecordingAndNeverItsScore() throws {
        // Present in any form: recording now, set to record, or a mark the client cannot read.
        for recording: [String: Any] in [["scheduleId": 4, "status": "recording"], ["scheduleId": 4, "status": "scheduled"],
                                         ["status": 7]] {
            let game = try XCTUnwrap(games(try Self.front([Self.game("g", recording: recording)])).first)
            XCTAssertTrue(game.recording, "\(recording)")
            XCTAssertNil(game.scores, "\(recording)")
            XCTAssertEqual(game.headline, "Green Bay Packers v Chicago Bears")
            XCTAssertEqual(game.context, "NFL · Q4 2:14 · Recording")
        }
    }

    func testTheHeadlineNeverShowsAScoreForARecordingGameEvenIfOneWasSaved() {
        let game = TopShelfSnapshot.Game(id: "g", title: "G", league: "NFL", clock: "Q1", sides: [
            .init(name: "A", code: "A", logo: nil), .init(name: "B", code: "B", logo: nil),
        ], scores: ["1", "2"], recording: true, channel: nil)
        XCTAssertEqual(game.headline, "A v B")
        XCTAssertEqual(game.playURL, game.gameURL, "no channel: Play opens the game")
    }

    // MARK: The snapshot

    func testTheSnapshotCarriesTheGamesOfARecentAnswer() throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let browse = BrowseModel(client: try server.client())
        browse.guide = GuideFixtures.channels()
        let answeredAt = Self.now.addingTimeInterval(-30)
        browse.sportFront.setFixture(try Self.front([Self.game("g", followed: true)]), answeredAt: answeredAt)
        let snapshot = try XCTUnwrap(browse.topShelfSnapshot(now: Self.now))
        XCTAssertEqual(snapshot.games?.map(\.id), ["g"])
        XCTAssertEqual(snapshot.gamesAt, answeredAt)
        XCTAssertFalse(snapshot.channels.isEmpty, "the channels are kept for when nothing is live")
        browse.sportFront.setFixture(try Self.front([Self.game("g", followed: true)]),
                                     answeredAt: Self.now.addingTimeInterval(-TopShelfSnapshot.gamesMaxAge - 1))
        XCTAssertNil(try XCTUnwrap(browse.topShelfSnapshot(now: Self.now)).games, "an old answer: the channels alone")
    }

    func testTheExtensionShowsGamesOnlyWhileTheirAnswerIsRecent() {
        let game = TopShelfSnapshot.Game(id: "g", title: "G", league: "NFL", clock: "Q1", sides: nil, scores: nil,
                                         recording: false, channel: nil)
        var snapshot = TopShelfSnapshot(kind: "channels", channels: [], savedAt: Self.now)
        XCTAssertEqual(snapshot.liveGames(at: Self.now), [], "no games: the channels")
        snapshot.games = Array(repeating: game, count: 12)
        snapshot.gamesAt = Self.now
        XCTAssertEqual(snapshot.liveGames(at: Self.now.addingTimeInterval(60)).count, 10, "capped")
        XCTAssertEqual(snapshot.liveGames(at: Self.now.addingTimeInterval(TopShelfSnapshot.gamesMaxAge + 1)), [], "too old")
        snapshot.gamesAt = nil
        XCTAssertEqual(snapshot.liveGames(at: Self.now), [], "of unknown age")
    }

    func testAnOlderSnapshotWithoutGamesStillReads() throws {
        let json = #"{"kind":"channels","channels":[],"savedAt":1800000000000}"#
        let snapshot = try XCTUnwrap(TopShelfSnapshot.decode(Data(json.utf8)))
        XCTAssertNil(snapshot.games)
        XCTAssertEqual(snapshot.liveGames(at: Self.now), [])
    }

    func testAChangedGameIsNotTheSameContent() {
        let game = TopShelfSnapshot.Game(id: "g", title: "G", league: "NFL", clock: "Q1", sides: nil, scores: ["1", "0"],
                                         recording: false, channel: nil)
        let a = TopShelfSnapshot(kind: "channels", channels: [], savedAt: Self.now, games: [game], gamesAt: Self.now)
        var b = a
        b.savedAt = Self.now.addingTimeInterval(60)
        XCTAssertTrue(b.sameContent(as: a), "only when it was saved differs")
        b.games?[0].clock = "Q2"
        XCTAssertFalse(b.sameContent(as: a))
        XCTAssertFalse(a.withoutScores.sameContent(as: a))
        XCTAssertNil(a.withoutScores.games?[0].scores)
    }

    // MARK: Switching scores off

    func testHideScoresRewritesTheSavedTopShelfWithoutScoresAtOnce() async throws {
        let container = try temporaryContainer()
        let saved = TopShelfExport.lastWritten
        defer { TopShelfExport.lastWritten = saved }
        let game = try XCTUnwrap(games(try Self.front([Self.game("g")])).first)
        XCTAssertEqual(game.scores, ["21", "17"], "control")
        let snapshot = TopShelfSnapshot(kind: "channels", channels: [], savedAt: Self.now, games: [game], gamesAt: Self.now)
        XCTAssertTrue(snapshot.write(container: container))
        TopShelfExport.lastWritten = snapshot
        let write = try XCTUnwrap(TopShelfExport.hideScores(generation: TopShelfPublication.shared.current, container: container))
        await write.value
        let read = try XCTUnwrap(TopShelfSnapshot.read(container: container))
        XCTAssertEqual(read.games?.map(\.id), ["g"], "the game stays, with where it is up to")
        XCTAssertNil(read.games?[0].scores, "its score is gone from the file")
        XCTAssertNil(TopShelfExport.lastWritten?.games?[0].scores)
    }

    func testHideScoresReadsTheFileWhenNothingWasWrittenThisLaunch() async throws {
        let container = try temporaryContainer()
        let saved = TopShelfExport.lastWritten
        defer { TopShelfExport.lastWritten = saved }
        let game = try XCTUnwrap(games(try Self.front([Self.game("g")])).first)
        XCTAssertTrue(TopShelfSnapshot(kind: "channels", channels: [], savedAt: Self.now, games: [game], gamesAt: Self.now)
            .write(container: container))
        TopShelfExport.lastWritten = nil
        await TopShelfExport.hideScores(generation: TopShelfPublication.shared.current, container: container)?.value
        XCTAssertNil(try XCTUnwrap(TopShelfSnapshot.read(container: container)).games?[0].scores)
    }

    func testHideScoresWritesNothingWhenThereIsNoScore() throws {
        let container = try temporaryContainer()
        let saved = TopShelfExport.lastWritten
        defer { TopShelfExport.lastWritten = saved }
        TopShelfExport.lastWritten = TopShelfSnapshot(kind: "channels", channels: [], savedAt: Self.now)
        XCTAssertNil(TopShelfExport.hideScores(generation: TopShelfPublication.shared.current, container: container))
    }

    // MARK: The game button

    func testTheGameLinkRoundTrips() {
        for id in ["espn:soccer/eng.1:1", "a+b c&d"] {
            XCTAssertEqual(PigTVLink.parseGame(PigTVLink.gameURL(id: id)), id)
        }
        XCTAssertNil(PigTVLink.parseGame(URL(string: "pigtv://game")!))
        XCTAssertNil(PigTVLink.parseGame(URL(string: "pigtv://play?sourceId=1&id=x")!))
        XCTAssertNil(PigTVLink.parse(PigTVLink.gameURL(id: "g")), "a game link is not a play link")
    }

    func testTheGameButtonMakesTheGameTheHeroOnceAnAnswerHasIt() throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let model = SportFrontModel(client: try server.client())
        model.requestHero("b")
        model.apply(try Self.front([Self.game("a", followed: true), Self.game("b")]))
        XCTAssertEqual(model.heroID, "b", "asked for before the answer")
        model.requestHero("a")
        XCTAssertEqual(model.heroID, "a", "asked for with the answer on screen")
        model.requestHero("gone")
        model.apply(try Self.front([Self.game("a", followed: true), Self.game("b")]))
        XCTAssertNil(model.requestedHero, "an answer without it drops the request")
        XCTAssertEqual(model.heroID, "a")
    }

    func testTheGameLinkClosesAnOpenPlayerFirstThenShowsTheGame() async throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let app = AppModel()
        app.injectHomeFixture()
        let browse = try XCTUnwrap(app.browse)
        app.configureClientForTesting(try server.client(), browse: browse)
        let two = browse.guide.prefix(2).map { SportEventChannel(sourceId: $0.sourceId, rawID: $0.rawID, name: $0.name) }
        app.playSportEvent(SportEvent(id: "e", title: "Event", league: "NFL", startTime: Self.ms - 60_000,
                                      endTime: Self.ms + 3_600_000, channels: two))
        XCTAssertNotNil(app.playback, "control: a player is up")
        app.requestedTab = nil
        app.open(PigTVLink.gameURL(id: "not-in-the-answer"))
        for _ in 0..<50 where app.requestedTab == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(app.playback, "the player was closed")
        XCTAssertEqual(app.requestedTab, "sport")
        XCTAssertEqual(browse.sportFront.requestedHero, "not-in-the-answer", "the hero once an answer has the game")
    }

    func testTheGameLinkWithNoPlayerShowsTheGameAtOnce() throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let app = AppModel()
        app.injectHomeFixture()
        let browse = try XCTUnwrap(app.browse)
        app.configureClientForTesting(try server.client(), browse: browse)
        app.requestedTab = nil
        app.open(PigTVLink.gameURL(id: "g"))
        XCTAssertEqual(app.requestedTab, "sport")
    }

    // MARK: Keeping the answer fresh

    func testTheFirstPassReadsHideScoresOnceAndAFailedReadKeepsScoresHidden() async throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let browse = BrowseModel(client: try server.client(extraFeatures: #""sportFront":true"#))
        await AppFreshness.refreshSportFrontIfStale(browse, topShelf: true)
        XCTAssertEqual(server.http.requests(path: "/api/sports/pages/preferences").count, 1, "read as the app opens")
        XCTAssertTrue(browse.f1Page.hidesSpoilers, "the fake server does not answer it: unknown, so hidden")
        await AppFreshness.refreshSportFrontIfStale(browse, topShelf: true)
        XCTAssertEqual(server.http.requests(path: "/api/sports/pages/preferences").count, 1, "once per session")
    }

    func testThePassAsksForTheSportFrontOnlyOnTheTelevisionWithTheServersFrontPage() async throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let without = BrowseModel(client: try server.client())
        await AppFreshness.refreshSportFrontIfStale(without, topShelf: true)
        XCTAssertTrue(server.http.requests(path: "/api/sports/front").isEmpty, "no front page on this server")
        let with = BrowseModel(client: try server.client(extraFeatures: #""sportFront":true"#))
        await AppFreshness.refreshSportFrontIfStale(with, topShelf: false)
        XCTAssertTrue(server.http.requests(path: "/api/sports/front").isEmpty, "no Top Shelf (iPhone, iPad)")
        await AppFreshness.refreshSportFrontIfStale(with, topShelf: true)
        XCTAssertEqual(server.http.requests(path: "/api/sports/front").count, 1)
    }
}
