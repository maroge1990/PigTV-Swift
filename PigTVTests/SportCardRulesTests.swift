import XCTest
@testable import PigTV

/// #345 (Mark, 18 Nov 2026): what selecting and holding a game card does, by the game's state, on every card. Over
/// `sport-front-0381.json` at its `now`: the cricket on Fox Cricket now (live on a channel), the Chiefs later on ESPN HD
/// (to come, listed), the Packers live with no channel, and a finished Packers game. Before #345 a card to come opened
/// the event page, a finished one did nothing, Remind me was a hero button and a card without a listing asked its
/// question in a dialog.
@MainActor
final class SportCardRulesTests: XCTestCase {
    static let cricket = "guide:ev-cricket"
    static let chiefs = "espn:football/nfl:406"
    static let packersLive = "espn:football/nfl:401"
    static let packersFinished = "espn:football/nfl:405"

    private func front(_ change: (inout [[String: Any]]) -> Void = { _ in }) throws -> SportFront {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: SportFrontTests.fixture()) as? [String: Any])
        var games = json["games"] as? [[String: Any]] ?? []
        change(&games)
        json["games"] = games
        return try JSONDecoder().decode(SportFront.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static func edit(_ games: inout [[String: Any]], _ id: String, _ change: (inout [String: Any]) -> Void) {
        for index in games.indices where games[index]["id"] as? String == id { change(&games[index]) }
    }

    /// The Chiefs' game with no listing yet (#234).
    private func unlisted() throws -> (SportsGame, Date) {
        let f = try front { Self.edit(&$0, Self.chiefs) { $0["channels"] = []; $0["events"] = []; $0["canWatch"] = false } }
        return (try XCTUnwrap(f.game(Self.chiefs)), Date(timeIntervalSince1970: f.now / 1000))
    }

    private func recording(_ json: String) throws -> Recording { try JSONDecoder().decode(Recording.self, from: Data(json.utf8)) }

    func testARecordingRowCarriesItsGameId() throws {
        let row = try recording(#"{"id":7,"title":"Packers v Bears","status":"completed","gameId":"espn:football/nfl:405"}"#)
        XCTAssertEqual(row.gameId, Self.packersFinished)
        XCTAssertNil(try recording(#"{"id":8,"title":"News","status":"completed"}"#).gameId, "an older server, or not a game")
        XCTAssertNil(try recording(#"{"id":9,"title":"News","status":"completed","gameId":null}"#).gameId)
    }

    func testSelectPlaysLiveRecordsBeforePlaysTheRecordingAfterElseNothing() throws {
        let f = try front()
        let now = Date(timeIntervalSince1970: f.now / 1000)
        XCTAssertEqual(SportCardRules.select(try XCTUnwrap(f.game(Self.cricket)), now: now, recordings: []), .watch, "on a channel now")
        XCTAssertEqual(SportCardRules.select(try XCTUnwrap(f.game(Self.chiefs)), now: now, recordings: []), .record,
                       "to come: the record page (it opened the event page)")
        XCTAssertEqual(SportCardRules.select(try XCTUnwrap(f.game(Self.packersLive)), now: now, recordings: []), .none,
                       "live on none of the household's channels")
        let (unlisted, at) = try unlisted()
        XCTAssertEqual(SportCardRules.select(unlisted, now: at, recordings: []), .recordWhenListed, "no listing yet: the record page's Record when it's listed")

        let finished = try XCTUnwrap(f.game(Self.packersFinished))
        let failed = try recording(#"{"id":9,"title":"Packers v Bears","status":"failed","started_at":1793393000000,"gameId":"espn:football/nfl:405"}"#)
        let other = try recording(#"{"id":3,"title":"Packers v Bears","status":"completed","gameId":"espn:football/nfl:999"}"#)
        let byTitle = try recording(#"{"id":4,"title":"Packers v Bears","status":"completed"}"#)
        let whole = try recording(#"{"id":7,"title":"Packers v Bears","status":"completed","is_partial":0,"duration_sec":10800,"started_at":1793392000000,"gameId":"espn:football/nfl:405"}"#)
        XCTAssertEqual(SportCardRules.select(finished, now: now, recordings: [failed, other, byTitle, whole]), .playRecording(7),
                       "the game's own finished recording")
        XCTAssertEqual(SportCardRules.select(finished, now: now, recordings: [failed, other, byTitle]), .none,
                       "never another game's, one that cannot play, or a guess by title")
        XCTAssertEqual(SportCardRules.select(finished, now: now, recordings: []), .none)
    }

    /// Several finished recordings of the game: a whole one before a partial, then the longest, then the earliest start
    /// (never just the newest). None finished but one still recording (finishing late) that plays while it records: that
    /// one, from its start (#345 review: its live edge is the coverage after the game, a spoiler).
    func testAFinishedGamePlaysItsBestRecording() throws {
        let finished = try XCTUnwrap(try front().game(Self.packersFinished))
        let now = Date(timeIntervalSince1970: try front().now / 1000)
        func row(_ id: Int, status: String = "completed", partial: Int = 0, length: Int = 10800, start: Double, live: Bool = false) throws -> Recording {
            try recording(#"{"id":\#(id),"title":"Packers v Bears","status":"\#(status)","is_partial":\#(partial),"duration_sec":\#(length),"started_at":\#(start),"watch_live":\#(live),"gameId":"espn:football/nfl:405"}"#)
        }
        let partialLong = try row(1, partial: 1, length: 12000, start: 1793391000000)
        let wholeShort = try row(2, length: 9000, start: 1793391500000)
        let wholeLongLate = try row(3, length: 10800, start: 1793392000000)
        let wholeLongEarly = try row(4, length: 10800, start: 1793391800000)
        XCTAssertEqual(SportCardRules.select(finished, now: now, recordings: [partialLong, wholeShort]), .playRecording(2), "whole before partial")
        XCTAssertEqual(SportCardRules.select(finished, now: now, recordings: [wholeShort, wholeLongLate]), .playRecording(3), "then the longest")
        XCTAssertEqual(SportCardRules.select(finished, now: now, recordings: [wholeLongLate, wholeLongEarly, wholeShort]), .playRecording(4),
                       "then the earliest start, not the newest")
        XCTAssertEqual(SportCardRules.select(finished, now: now, recordings: [partialLong]), .playRecording(1), "a partial one when it is all there is")

        let going = try row(5, status: "recording", start: 1793391000000, live: true)
        let goingNoLive = try row(6, status: "recording", start: 1793391000000, live: false)
        XCTAssertEqual(SportCardRules.select(finished, now: now, recordings: [going]), .playRecordingFromStart(5),
                       "still recording: from its start, never the live edge (the coverage after the game)")
        XCTAssertEqual(SportCardRules.select(finished, now: now, recordings: [going, wholeShort]), .playRecording(2), "a finished one first")
        XCTAssertEqual(SportCardRules.select(finished, now: now, recordings: [goingNoLive]), .none, "one that cannot play while it records")
    }

    func testNextRoundIsNothing() throws {
        let now = Date(timeIntervalSince1970: try front().now / 1000)
        let next = try front { Self.edit(&$0, Self.chiefs) { $0["nextRound"] = true } }
        XCTAssertEqual(SportCardRules.select(try XCTUnwrap(next.game(Self.chiefs)), now: now, recordings: []), .none, "next round")
    }

    func testSelectIsDecidedAtThePress() throws {
        let f = try front()
        let chiefs = try XCTUnwrap(f.game(Self.chiefs))
        let event = try XCTUnwrap(SportFrontText.event(chiefs))
        let best = try XCTUnwrap(event.best)
        XCTAssertEqual(SportCardRules.select(chiefs, now: event.start(on: best).addingTimeInterval(60), recordings: []), .watch,
                       "a card drawn before the start plays once it airs")
        XCTAssertEqual(SportCardRules.select(chiefs, now: event.end(on: best).addingTimeInterval(60), recordings: []), .none,
                       "its airing over: nothing left to watch or record")
    }

    func testHoldOffersAnotherChannelAndRecordLiveRecordAndRemindBeforeNothingAfter() throws {
        let f = try front()
        let now = Date(timeIntervalSince1970: f.now / 1000)
        XCTAssertEqual(SportCardRules.hold(try XCTUnwrap(f.game(Self.cricket)), now: now),
                       .init(watchAnother: false, record: true, remind: false), "one channel: no other to choose")
        let two = try front { Self.edit(&$0, Self.cricket) { game in
            var channels = game["channels"] as? [[String: Any]] ?? []
            var copy = channels[0]
            copy["id"] = "\(copy["id"] ?? "")-2"
            copy["name"] = "Kayo"
            channels.append(copy)
            game["channels"] = channels
        } }
        XCTAssertEqual(SportCardRules.hold(try XCTUnwrap(two.game(Self.cricket)), now: now),
                       .init(watchAnother: true, record: true, remind: false), "live on two channels: Watch another channel")
        XCTAssertEqual(SportCardRules.hold(try XCTUnwrap(f.game(Self.chiefs)), now: now),
                       .init(watchAnother: false, record: true, remind: true), "to come: RECORD and Remind me")
        let (unlisted, at) = try unlisted()
        XCTAssertEqual(SportCardRules.hold(unlisted, now: at), .init(record: true), "no listing: RECORD (Record when it's listed) only")
        XCTAssertEqual(SportCardRules.hold(try XCTUnwrap(f.game(Self.packersFinished)), now: now), .init(), "finished: nothing of its own")
        XCTAssertFalse(SportCardRules.hold(try XCTUnwrap(f.game(Self.packersFinished)), now: now).offersAnything, "so no menu (F1's tiles)")
        XCTAssertTrue(SportCardRules.hold(try XCTUnwrap(f.game(Self.chiefs)), now: now).offersAnything)
        XCTAssertEqual(SportCardRules.hold(try XCTUnwrap(f.game(Self.packersLive)), now: now), .init(), "live on no channel")
    }

    /// #345 review: live means on air on any of its channels, not only the best: select plays (the best of those on
    /// air), and Watch another channel counts channel names on air, never a name's other qualities (D-65).
    func testLiveIsAnyChannelOnAirAndAnotherChannelIsAnotherName() throws {
        let raw = try front()
        let now = Date(timeIntervalSince1970: raw.now / 1000)
        let onAir: (String, String, String) -> [String: Any] = { id, name, quality in
            ["sourceId": 1, "id": id, "stableId": id, "name": name, "number": NSNull(), "logo": NSNull(), "quality": quality,
             "start": raw.now - 600_000, "end": raw.now + 7_200_000]
        }
        func chiefs(_ extra: [[String: Any]]) throws -> SportsGame {
            let f = try front { Self.edit(&$0, Self.chiefs) { game in
                game["channels"] = (game["channels"] as? [[String: Any]] ?? []) + extra
            } }
            return try XCTUnwrap(f.game(Self.chiefs))
        }
        let one = try chiefs([onAir("k1", "Kayo", "HD")])
        XCTAssertEqual(SportCardRules.select(one, now: now, recordings: []), .watch, "its best channel later, another on air now")
        XCTAssertEqual(SportCardRules.playable(try XCTUnwrap(SportFrontText.event(one)), now: now)?.channels.map(\.name), ["Kayo"],
                       "the one on air plays")
        XCTAssertEqual(SportCardRules.hold(one, now: now), .init(watchAnother: false, record: true, remind: false))
        let qualities = try chiefs([onAir("k1", "Kayo", "HD"), onAir("k2", "Kayo", "UHD")])
        XCTAssertFalse(SportCardRules.hold(qualities, now: now).watchAnother, "one name in two qualities is one channel")
        let two = try chiefs([onAir("k1", "Kayo", "HD"), onAir("f1", "Fox Footy", "HD")])
        XCTAssertTrue(SportCardRules.hold(two, now: now).watchAnother, "two names on air")
    }

    /// #345 sign-off: the hero's and the iPhone card's Watch, the player's live games and choosing one there use the
    /// same "live on any channel on air" as the cards.
    func testWatchEverywhereIsAnyChannelOnAir() throws {
        let raw = try front()
        let now = Date(timeIntervalSince1970: raw.now / 1000)
        let f = try front { Self.edit(&$0, Self.packersLive) { game in
            game["channels"] = [
                ["sourceId": 1, "id": "e1", "stableId": "e1", "name": "ESPN HD", "number": NSNull(), "logo": NSNull(), "quality": "HD",
                 "start": raw.now + 3_600_000, "end": raw.now + 9_000_000],
                ["sourceId": 1, "id": "k1", "stableId": "k1", "name": "Kayo", "number": NSNull(), "logo": NSNull(), "quality": "HD",
                 "start": raw.now - 600_000, "end": raw.now + 7_200_000],
            ]
        } }
        let game = try XCTUnwrap(f.game(Self.packersLive))
        XCTAssertEqual(SportFrontText.action(game, now: now), .watch, "the hero's and the iPhone card's Watch (it said Remind me)")
        XCTAssertEqual(SportFrontText.playable(game, at: now)?.channels.map(\.name), ["Kayo"], "plays the channel on air")
        XCTAssertEqual(SportFrontText.actionLabel(game, now: now), "Watch")
        XCTAssertTrue(PlayerGames.list(f, hidden: false, now: now).contains { $0.game.id == Self.packersLive },
                      "the player's live games list it")
    }

    /// #345 review: a session card's action word is what pressing it does: never Remind me or Details.
    func testASessionCardsActionWordIsWhatSelectDoes() throws {
        let f = try front()
        let now = Date(timeIntervalSince1970: f.now / 1000)
        XCTAssertEqual(SportFrontText.actionLabel(try XCTUnwrap(f.game(Self.cricket)), now: now), "Watch")
        XCTAssertEqual(SportFrontText.actionLabel(try XCTUnwrap(f.game(Self.chiefs)), now: now), "Record", "it said Remind me")
        XCTAssertEqual(SportFrontText.actionLabel(try XCTUnwrap(f.game(Self.packersFinished)), now: now), "")
        XCTAssertEqual(SportFrontText.actionLabel(try XCTUnwrap(f.game(Self.packersLive)), now: now), "", "it said Not on your channels")
    }

    /// #345 review: a fixture whose C-R card has no channel yet, while the fixture's own event has one, keeps its RECORD
    /// section on that event (as before #345); a finished card has none.
    func testAFixtureCardWithoutAChannelHoldsOnTheFixturesEvent() throws {
        let (unlisted, now) = try unlisted()
        let listed = try XCTUnwrap(try front().game(Self.chiefs))
        let fixtureEvent = try XCTUnwrap(SportFrontText.event(listed))
        XCTAssertEqual(SportCardRules.menuEvent(game: unlisted, event: fixtureEvent)?.channels.map(\.name), ["ESPN HD"])
        XCTAssertEqual(SportCardRules.hold(game: unlisted, event: fixtureEvent, now: now), .init(record: true, remind: true))
        XCTAssertEqual(SportCardRules.menuEvent(game: listed, event: nil)?.id, fixtureEvent.id, "the card's own when it has one")
        XCTAssertEqual(SportCardRules.hold(game: unlisted, event: nil, now: now), .init(record: true), "no event: Record when it's listed")
        let finished = try XCTUnwrap(try front().game(Self.packersFinished))
        XCTAssertNil(SportCardRules.menuEvent(game: finished, event: fixtureEvent))
        XCTAssertEqual(SportCardRules.hold(game: finished, event: fixtureEvent, now: now), .init())
    }

    /// The hero and the iPhone carousel card keep Watch and Record; Remind me is only in the hold menu.
    func testRemindMeIsNoLongerACardButton() {
        XCTAssertEqual(SportPhoneCardButtons.primary(.watch), "Watch")
        XCTAssertNil(SportPhoneCardButtons.primary(.remind))
    }

    /// The record page for a game with no listing: "This game" is its `game` rule (with the padding chosen), or Don't
    /// record it once set; the team and league rules as for any game.
    func testTheRecordPageOffersRecordWhenListed() throws {
        let browse = BrowseModel(client: APIClient(address: try ServerAddress("http://127.0.0.1:9"), token: "fixture", accountID: 1),
                                 accountID: 1)
        let (game, now) = try unlisted()
        let f = try front()
        browse.sportFront.setFixture(f)
        XCTAssertNil(browse.recordRequest(listing: try XCTUnwrap(f.game(Self.chiefs)), now: now), "it has a listing")
        let request = try XCTUnwrap(browse.recordRequest(listing: game, now: now))
        XCTAssertTrue(request.airings.isEmpty)
        XCTAssertEqual(request.gameId, Self.chiefs)
        XCTAssertEqual(request.listing?.offer, .record)
        XCTAssertEqual(RecordPlan.primaryTitle(.this, request: request), "Record when it's listed")
        XCTAssertEqual(RecordPlan.whats(request).first, .this)
        XCTAssertTrue(RecordPlan.whats(request).contains(.everyLeague("NFL")))
        XCTAssertEqual(RecordPlan.label(.this, request: request, now: now).detail?.isEmpty, false, "its start")
        XCTAssertEqual(RecordPlan.stopTitle(request), "When the game ends (ESPN)")
        let set = try XCTUnwrap(browse.recordRequest(listing: game, answered: .init(basis: nil, rule: 12), now: now))
        XCTAssertEqual(set.listing?.offer, .cancel(ruleId: 12))
        XCTAssertEqual(RecordPlan.primaryTitle(.this, request: set), "Don't record it")
        XCTAssertEqual(RecordPlan.primaryTitle(.everyLeague("NFL"), request: set), "Record every game")
    }
}
