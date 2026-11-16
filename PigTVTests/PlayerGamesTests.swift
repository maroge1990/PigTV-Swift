import XCTest
@testable import PigTV

/// #334 (D-67): a live play started from Sport lists the other live games in the player (not the channels). The list is
/// built from the Sport front page's answer: under way or on air with a channel, followed first, each group in the
/// answer's order; scores follow D-66 (hidden when the household hides them, when the game is recording, without the
/// scores feed, or when none came: fail closed); a game is chosen on its preferred channel.
@MainActor
final class PlayerGamesTests: XCTestCase {
    private static let now = Date().timeIntervalSince1970 * 1000

    private static func channel(_ id: String, _ name: String) -> [String: Any] {
        ["sourceId": 1, "id": id, "name": name]
    }

    private static func game(_ id: String, league: String = "NFL", status: String = "live", followed: Bool = false,
                             competitors: [[String: Any]]? = nil, scores: [String]? = ["7", "3"],
                             channels: [[String: Any]]? = nil, recording: [String: Any]? = nil,
                             onAir: Bool? = nil, freshness: String = "fresh") -> [String: Any] {
        var game: [String: Any] = [
            "id": id, "league": league, "title": "Game \(id)", "start": now - 600_000, "status": status,
            "freshness": freshness, "progress": ["clock": "5:00", "period": 2],
            "availability": "matched", "broadcastStatus": "on-tv",
            "channels": channels ?? [channel("ch-\(id)", "Channel \(id)")], "events": [], "canWatch": true,
            "competitors": competitors ?? [["id": "1", "name": "Green Bay Packers", "logo": "/api/logo/gb"],
                                           ["id": "2", "name": "Chicago Bears"]],
            "followed": followed,
        ]
        if let scores { game["scores"] = scores }
        if let recording { game["recording"] = recording }
        if let onAir { game["onAir"] = onAir }
        return game
    }

    private static func front(_ games: [[String: Any]], spoilerFree: Bool = false, scores: String = "fresh") throws -> SportFront {
        let json: [String: Any] = ["now": now, "spoilerFree": spoilerFree, "scores": scores, "sports": [], "follows": [],
                                   "rails": [], "games": games]
        return try JSONDecoder().decode(SportFront.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: Which games, in which order

    func testOnlyGamesUnderWayOrOnAirWithAChannelAreListed() throws {
        let front = try Self.front([
            Self.game("live"), Self.game("break", status: "break"), Self.game("suspended", status: "suspended"),
            Self.game("onair", status: "scheduled", onAir: true),
            Self.game("later", status: "scheduled"), Self.game("done", status: "finished"),
            Self.game("nochannel", channels: []),
        ])
        XCTAssertEqual(PlayerGames.list(front, hidden: false).map(\.id), ["live", "break", "suspended", "onair"])
        XCTAssertEqual(PlayerGames.list(nil, hidden: false), [], "no answer yet: no games")
    }

    func testFollowedGamesComeFirstThenTheRestEachInTheAnswersOrder() throws {
        let front = try Self.front([
            Self.game("a"), Self.game("b", followed: true), Self.game("c"), Self.game("d", followed: true),
        ])
        XCTAssertEqual(PlayerGames.list(front, hidden: false).map(\.id), ["b", "d", "a", "c"])
    }

    // MARK: Scores (D-66)

    func testScoresShowWhenNothingHidesThem() throws {
        let row = try XCTUnwrap(PlayerGames.list(try Self.front([Self.game("g")]), hidden: false).first)
        XCTAssertEqual(row.sides?.map(\.score), ["7", "3"])
        XCTAssertFalse(row.recording)
    }

    func testTheHouseholdsHideScoresHidesThem() throws {
        let row = try XCTUnwrap(PlayerGames.list(try Self.front([Self.game("g")]), hidden: true).first)
        XCTAssertEqual(row.sides?.map(\.score), [nil, nil])
        let answer = try XCTUnwrap(PlayerGames.list(try Self.front([Self.game("g")], spoilerFree: true), hidden: false).first)
        XCTAssertEqual(answer.sides?.map(\.score), [nil, nil], "the answer's own switch hides too")
    }

    func testARecordingGameShowsRecordingAndNoScore() throws {
        for recording: [String: Any] in [["scheduleId": 4, "status": "recording"], ["scheduleId": 4, "status": "scheduled"],
                                         ["status": 7]] {
            let row = try XCTUnwrap(PlayerGames.list(try Self.front([Self.game("g", recording: recording)]), hidden: false).first)
            XCTAssertTrue(row.recording, "\(recording)")
            XCTAssertEqual(row.sides?.map(\.score), [nil, nil], "a game being recorded never shows its score: \(recording)")
        }
    }

    func testScoresFailClosed() throws {
        let noFeed = try XCTUnwrap(PlayerGames.list(try Self.front([Self.game("g")], scores: "unavailable"), hidden: false).first)
        XCTAssertEqual(noFeed.sides?.map(\.score), [nil, nil], "without the scores feed")
        let none = try XCTUnwrap(PlayerGames.list(try Self.front([Self.game("g", scores: nil)]), hidden: false).first)
        XCTAssertEqual(none.sides?.map(\.score), [nil, nil], "the server sent none")
        let stale = try XCTUnwrap(PlayerGames.list(try Self.front([Self.game("g", freshness: "stale")]), hidden: false).first)
        XCTAssertEqual(stale.sides?.map(\.score), [nil, nil], "a stale game")
        let one = try XCTUnwrap(PlayerGames.list(try Self.front([Self.game("g", scores: ["7"])]), hidden: false).first)
        XCTAssertEqual(one.sides?.map(\.score), [nil, nil], "not one per side")
    }

    /// The account's preference unknown counts as hidden (F1PageModel.hidesSpoilers): the models as they are before the
    /// preferences have been read.
    func testUnknownPreferenceHidesScores() throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let browse = BrowseModel(client: try server.client())
        browse.sportFront.setFixture(try Self.front([Self.game("g")]))
        XCTAssertTrue(browse.f1Page.hidesSpoilers, "control: the preference is not known yet")
        let row = try XCTUnwrap(PlayerGames.current(front: browse.sportFront, preferences: browse.f1Page).first)
        XCTAssertEqual(row.sides?.map(\.score), [nil, nil])
    }

    // MARK: Team codes, races

    func testTheCodeIsTheAbbreviationElseTheFirstThreeLetters() throws {
        let front = try Self.front([Self.game("g", competitors: [
            ["id": "1", "name": "Green Bay Packers", "abbreviation": "GB"],
            ["id": "2", "name": "St. Kilda", "abbreviation": ""],
        ]), Self.game("h", competitors: [
            ["id": "3", "name": "Bears", "abbreviation": 12],
            ["id": "4", "name": "49ers"],
        ])])
        let rows = PlayerGames.list(front, hidden: false)
        XCTAssertEqual(rows.map(\.id), ["g", "h"], "a malformed abbreviation never drops the game")
        XCTAssertEqual(rows[0].sides?.map(\.code), ["GB", "STK"])
        XCTAssertEqual(rows[1].sides?.map(\.code), ["BEA", "49E"])
    }

    func testARaceHasItsTitleAndClockButNoScoreBug() throws {
        let front = try Self.front([Self.game("f1", league: "F1", competitors: [], scores: nil),
                                    Self.game("one", league: "AFL", competitors: [["id": "1", "name": "Solo"]])])
        let rows = PlayerGames.list(front, hidden: false)
        XCTAssertEqual(rows.map(\.id), ["f1", "one"])
        XCTAssertNil(rows[0].sides)
        XCTAssertEqual(rows[0].title, "Game f1")
        XCTAssertFalse(rows[0].clock.isEmpty)
        XCTAssertNil(rows[1].sides, "not two competitors")
    }

    func testTheClockIsWhereTheGameIsUpTo() throws {
        let row = try XCTUnwrap(PlayerGames.list(try Self.front([Self.game("g")]), hidden: false).first)
        XCTAssertEqual(row.clock, "Q2 5:00")
    }

    // MARK: The playing row, the notice, selection

    func testThePlayingRowAndWhetherThereIsAnotherGame() throws {
        let front = try Self.front([Self.game("a"), Self.game("b", channels: [Self.channel("x", "X"), Self.channel("y", "Y")])])
        let rows = PlayerGames.list(front, hidden: false)
        XCTAssertEqual(PlayerGames.playing(rows, eventID: "b", channelID: nil), 1, "the event the play began with")
        XCTAssertEqual(PlayerGames.playing(rows, eventID: "gone", channelID: "1:y"), 1, "else the game on the channel")
        XCTAssertEqual(PlayerGames.playing(rows, eventID: nil, channelID: "1:ch-a"), 0)
        XCTAssertNil(PlayerGames.playing(rows, eventID: nil, channelID: "1:z"))
        XCTAssertTrue(PlayerGames.hasOthers(rows, playing: 0))
        let alone = PlayerGames.list(try Self.front([Self.game("a")]), hidden: false)
        XCTAssertFalse(PlayerGames.hasOthers(alone, playing: 0), "only this game live: no list")
        XCTAssertFalse(PlayerGames.hasOthers([], playing: nil))
        XCTAssertTrue(PlayerGames.hasOthers(alone, playing: nil), "a live game that is not the one playing")
        XCTAssertEqual(PlayerGames.noOthers, "No other games live")
        XCTAssertEqual(PlayerGames.header, "Live games")
    }

    /// Selecting a game plays its preferred channel (the first) with no picker, and the player stays in games mode; a play
    /// from the TV Guide, and the end of the play, list channels again.
    func testSelectingAGamePlaysItsPreferredChannelAndKeepsTheGamesList() async throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let app = AppModel()
        app.injectHomeFixture(sportFront: true)
        let browse = try XCTUnwrap(app.browse)
        app.configureClientForTesting(try server.client(), browse: browse)
        let rows = browse.guide.prefix(4).map { ["sourceId": $0.sourceId, "id": $0.rawID, "name": $0.name] as [String: Any] }
        let front = try Self.front([Self.game("first", channels: [rows[0]]), Self.game("second", channels: [rows[1], rows[2]])])
        let games = PlayerGames.list(front, hidden: false)
        let first = try XCTUnwrap(SportFrontText.event(games[0].game))
        app.playSportEvent(first)
        XCTAssertTrue(app.playerShowsGames, "a play from Sport lists the live games")
        XCTAssertEqual(app.sportPlay?.eventID, first.id)

        app.playSportGame(games[1])
        XCTAssertEqual(app.playback?.channel.id, browse.asChannel(browse.guide[1]).id, "the game's preferred channel")
        XCTAssertTrue(app.playerShowsGames, "still the live games")
        XCTAssertEqual(PlayerGames.playing(games, eventID: app.sportPlay?.eventID, channelID: app.playback?.channel.id), 1)

        app.playSportEvent(first, origin: "TV Guide", fromSport: false)
        XCTAssertFalse(app.playerShowsGames, "the TV Guide's Watch on lists channels")
        app.playSportEvent(first)
        XCTAssertTrue(app.playerShowsGames)
        app.zapList = [browse.asChannel(browse.guide[3])]
        XCTAssertFalse(app.playerShowsGames, "a play that sets its own channel list leaves the games")
        app.playSportEvent(first)
        let playback = try XCTUnwrap(app.playback)
        await app.endPlayback(playback)
        XCTAssertNil(app.sportPlay, "ending the play forgets it")
    }

    /// The games list needs the server's Sport front page: without it the player lists the event's channels as before.
    func testWithoutTheSportFrontPageThePlayerListsChannels() async throws {
        let server = try FakePigTVServer()
        defer { server.http.stop() }
        let app = AppModel()
        app.injectHomeFixture(sportFront: false)
        let browse = try XCTUnwrap(app.browse)
        app.configureClientForTesting(try server.client(), browse: browse)
        let two = browse.guide.prefix(2).map { SportEventChannel(sourceId: $0.sourceId, rawID: $0.rawID, name: $0.name) }
        app.playSportEvent(SportEvent(id: "e", title: "Event", league: "AFL", startTime: Self.now - 60_000,
                                      endTime: Self.now + 3_600_000, channels: two))
        XCTAssertNotNil(app.sportPlay)
        XCTAssertFalse(app.playerShowsGames)
        if let playback = app.playback { await app.endPlayback(playback) }
    }
}
