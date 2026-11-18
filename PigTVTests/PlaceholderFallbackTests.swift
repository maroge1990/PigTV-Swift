import XCTest
import AVFoundation
@testable import PigTV

// #348 (Apple part): a play from a Sport game names the game in its resolve (`eventId`); a resolve answer's `fallback`
// (the channel asked for was the provider's placeholder and the server played the game's next channel) gives the player
// that channel's identity and a short notice; the player's list for a play from Sport carries the game's own channels.
// Before this change none of it existed (ResolveFallback, PlaybackModel.adopt, ResolveBody.eventId,
// PlayerGames.gameChannels: these tests fail to compile on 319).
@MainActor
final class PlaceholderFallbackTests: XCTestCase {
    private static let fallbackJSON = #""fallback":{"reason":"placeholder","from":{"sourceId":1,"id":"pos_10","name":"Sportsnet Event"},"to":{"sourceId":1,"id":"pos_11","stableId":"s1803790","name":"Sportsnet One"}}"#
    private static func answer(_ extra: String = "") -> String {
        #"{"strategy":"transcode","url":"/api/transcode/s1/master.m3u8","sessionId":"s1","container":"hls","videoMode":"copy"\#(extra)}"#
    }

    private func decision(_ json: String) throws -> PlaybackDecision {
        try JSONDecoder().decode(PlaybackDecision.self, from: Data(json.utf8))
    }

    private func channel(_ id: String, _ name: String, stable: String? = nil) -> Channel {
        Channel(rawID: id, sourceId: 1, name: name, logo: nil, category: nil, now: nil, next: nil, stableId: stable)
    }

    // MARK: Decoding (additive, tolerant)

    func testTheAnswersFallbackIsRead() throws {
        let fallback = try XCTUnwrap(try decision(Self.answer("," + Self.fallbackJSON)).fallback)
        XCTAssertEqual(fallback.reason, "placeholder")
        XCTAssertEqual(fallback.from.name, "Sportsnet Event")
        XCTAssertEqual(fallback.to, .init(sourceId: 1, id: "pos_11", stableId: "s1803790", name: "Sportsnet One"))
        XCTAssertEqual(fallback.toChannelID, "1:pos_11")
        XCTAssertEqual(fallback.notice, "Sportsnet Event has nothing on · Playing Sportsnet One")
    }

    func testNoFallbackChangesNothing() throws {
        XCTAssertNil(try decision(Self.answer()).fallback, "an older server, or an ordinary play")
        XCTAssertNil(try decision(Self.answer(#","fallback":null"#)).fallback)
    }

    func testAMalformedFallbackIsAbsentAndThePlayStillDecodes() throws {
        for odd in [#""fallback":{"reason":"placeholder","from":{"name":"A"},"to":{"sourceId":1,"name":"B"}}"#, // no to.id
                    #""fallback":{"from":{"name":"A"},"to":{"sourceId":"1","id":"x","name":"B"}}"#, // a string sourceId
                    #""fallback":{"from":{"name":""},"to":{"sourceId":1,"id":"x","name":"B"}}"#, // no from name
                    #""fallback":"placeholder""#, #""fallback":[]"#] {
            let decoded = try decision(Self.answer("," + odd))
            XCTAssertNil(decoded.fallback, odd)
            XCTAssertEqual(decoded.sessionId, "s1")
        }
    }

    func testAnotherReasonStillNamesTheChannelPlayed() throws {
        let json = Self.fallbackJSON.replacingOccurrences(of: "placeholder", with: "something-new")
        XCTAssertEqual(try decision(Self.answer("," + json)).fallback?.notice, "Playing Sportsnet One")
    }

    func testTheResolveNamesTheGameOnlyWhenThereIsOne() throws {
        let encoder = JSONEncoder()
        let plain = try JSONSerialization.jsonObject(with: encoder.encode(
            ResolveBody(sourceId: 1, channelId: "pos_10", capabilities: [:]))) as? [String: Any]
        XCTAssertNil(plain?["eventId"], "absent, not null, for a play that is not from a game")
        let game = try JSONSerialization.jsonObject(with: encoder.encode(
            ResolveBody(sourceId: 1, channelId: "pos_10", capabilities: [:], eventId: "espn:nhl:401"))) as? [String: Any]
        XCTAssertEqual(game?["eventId"] as? String, "espn:nhl:401")
    }

    func testOnlyThePlayOfOneOfTheGamesChannelsNamesTheGame() {
        let one = channel("pos_10", "Sportsnet Event"), two = channel("pos_11", "Sportsnet One")
        let play = SportPlay(eventID: "espn:nhl:401", serverEventID: "espn:nhl:401")
        XCTAssertEqual(AppModel.fallbackEventID(sportPlay: play, zapList: [one, two], channel: two), "espn:nhl:401")
        XCTAssertNil(AppModel.fallbackEventID(sportPlay: play, zapList: [one, two], channel: channel("pos_99", "Typed in")),
                     "Go to number to another channel is not the game's")
        XCTAssertNil(AppModel.fallbackEventID(sportPlay: nil, zapList: [one, two], channel: one), "not a play from Sport")
    }

    /// Codex review of 320: only the server's own C-I event id is sent; an event a page built (an F1 session, a cricket
    /// match, a fixture with no card) has none, so the server keeps its own inference.
    func testOnlyAServerEventIdIsSentAsTheGame() throws {
        let one = channel("pos_10", "Sportsnet Event"), two = channel("pos_11", "Sportsnet One")
        let built = SportEvent(id: "cricket:1", title: "A v B", league: "Cricket", startTime: 1, endTime: 2, channels: [])
        XCTAssertNil(built.serverEventID)
        XCTAssertNil(AppModel.fallbackEventID(sportPlay: SportPlay(eventID: built.id, serverEventID: built.serverEventID),
                                              zapList: [one, two], channel: one), "a page-built event: no eventId")
        let decoded = try JSONDecoder().decode(SportEvent.self, from: Data(#"{"id":"ci-77","title":"Leafs v Habs","start":1,"end":2,"channels":[]}"#.utf8))
        XCTAssertEqual(decoded.serverEventID, "ci-77", "a C-I event is the server's")
        XCTAssertEqual(WatchOn.onAir(decoded, now: Date()).serverEventID, "ci-77", "kept when narrowed to its channels on air")
    }

    // MARK: The player takes the channel played

    func testAFallbackGivesThePlayerTheChannelPlayedAndANotice() throws {
        let client = APIClient(address: try ServerAddress("http://127.0.0.1:9"), token: "fixture")
        let asked = channel("pos_10", "Sportsnet Event")
        let playback = PlaybackModel(channel: asked, client: client)
        let listed = channel("pos_11", "Sportsnet One", stable: "s1803790")
        let now = Date().timeIntervalSince1970 * 1000
        let guide = [GuideProgramme(title: "NHL: Leafs v Habs", description: nil, startTime: now - 60_000, endTime: now + 3_600_000)]
        playback.fallbackChannel = { side in side.id == "pos_11" ? (listed, guide) : nil }
        let fallback = try XCTUnwrap(try decision(Self.answer("," + Self.fallbackJSON)).fallback)
        playback.adopt(fallback)
        XCTAssertEqual(playback.channel, listed, "the name, logo, favourite and next resolve are the channel played")
        XCTAssertEqual(playback.programme()?.title, "NHL: Leafs v Habs", "its guide")
        XCTAssertEqual(playback.fallbackNotice, "Sportsnet Event has nothing on · Playing Sportsnet One")
        // Not in the list or the guide: built from the answer's own fields.
        let bare = PlaybackModel(channel: asked, client: client)
        bare.adopt(fallback)
        XCTAssertEqual(bare.channel.id, "1:pos_11")
        XCTAssertEqual(bare.channel.name, "Sportsnet One")
        XCTAssertEqual(bare.channel.stableId, "s1803790")
    }

    /// Codex review of 320 (high): `to` names pos_11 with its stable id; the game's list has a pos_11 that is another
    /// channel now (positions are reused after a reorder). The cached pos_11 is not taken; an entry with the same stable
    /// id (at another position) only adds its logo and number; the identity stays the server's.
    func testAReusedPositionIsNotTakenForTheChannelPlayed() {
        let app = AppModel()
        let side = ResolveFallback.Side(sourceId: 1, id: "pos_11", stableId: "s1803790", name: "Sportsnet One")
        let reused = Channel(rawID: "pos_11", sourceId: 1, name: "Golf Channel", logo: "/logo/golf", category: nil, now: nil,
                             next: nil, stableId: "s999", number: 611)
        app.zapList = [reused]
        XCTAssertNil(app.fallbackChannel(side), "a different stable id at the same position is another channel")
        let moved = Channel(rawID: "pos_12", sourceId: 1, name: "Sportsnet One", logo: "/logo/sn1", category: nil, now: nil,
                            next: nil, stableId: "s1803790", number: 412)
        app.zapList = [reused, moved]
        let found = app.fallbackChannel(side)?.0
        XCTAssertEqual(found?.id, "1:pos_11", "the server's identity: what the next resolve and a recording use")
        XCTAssertEqual(found?.stableId, "s1803790")
        XCTAssertEqual(found?.logo, "/logo/sn1", "enriched from the same channel's entry")
        XCTAssertEqual(found?.number, 412)
        // Codex sign-off of 320: without a stable id in the answer, Golf Channel cached at pos_11 is not Sportsnet One:
        // neither its identity nor its logo is taken, and the adopted channel keeps no stable id.
        let plain = ResolveFallback.Side(sourceId: 1, id: "pos_11", name: "Sportsnet One")
        XCTAssertNil(app.fallbackChannel(plain), "another name at the same position: not enriched")
        let client = APIClient(address: try! ServerAddress("http://127.0.0.1:9"), token: "fixture")
        let playback = PlaybackModel(channel: channel("pos_10", "Sportsnet Event"), client: client)
        playback.fallbackChannel = { app.fallbackChannel($0) }
        playback.adopt(ResolveFallback(reason: "placeholder", from: .init(sourceId: 1, id: "pos_10", name: "Sportsnet Event"),
                                       to: plain))
        XCTAssertEqual(playback.channel.id, "1:pos_11")
        XCTAssertEqual(playback.channel.name, "Sportsnet One")
        XCTAssertNil(playback.channel.stableId, "no stable id taken from Golf Channel")
        XCTAssertNil(playback.channel.logo, "nor its logo")
        XCTAssertNil(playback.channel.number)
        // The same id and name is the same channel: enriched, its stable id still the answer's (none).
        let same = Channel(rawID: "pos_11", sourceId: 1, name: "Sportsnet One", logo: "/logo/sn1", category: nil, now: nil,
                           next: nil, stableId: "s1803790", number: 412)
        app.zapList = [same]
        let enriched = app.fallbackChannel(plain)?.0
        XCTAssertEqual(enriched?.logo, "/logo/sn1")
        XCTAssertNil(enriched?.stableId, "the answer's stable id, exactly")
    }

    func testAFallbackToTheSameChannelChangesNothing() throws {
        let client = APIClient(address: try ServerAddress("http://127.0.0.1:9"), token: "fixture")
        let playback = PlaybackModel(channel: channel("pos_11", "Sportsnet One"), client: client)
        playback.adopt(try XCTUnwrap(try decision(Self.answer("," + Self.fallbackJSON)).fallback))
        XCTAssertNil(playback.fallbackNotice)
    }

    /// Against the fake server: the resolve carries `eventId`, and its `fallback` answer switches the playing channel.
    func testAResolveAnsweredWithAFallbackPlaysAsTheChannelPlayed() async throws {
        guard HLSFixture.isComplete else { throw XCTSkip("HLS fixture missing") }
        let server = try FakePigTVServer { count, _ in
            .json(#"{"strategy":"transcode","url":"/api/transcode/s\#(count)/master.m3u8","sessionId":"s\#(count)","container":"hls","videoMode":"copy","info":{"fps":"25/1","video":"h264","width":320,"height":180},\#(Self.fallbackJSON)}"#)
        }
        let playback = PlaybackModel(channel: channel("pos_10-\(UUID().uuidString.prefix(6))", "Sportsnet Event"),
                                     client: try server.client())
        playback.eventID = "espn:nhl:401"
        playback.start()
        let deadline = Date().addingTimeInterval(10)
        while playback.channel.rawID != "pos_11", Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(playback.channel.id, "1:pos_11")
        XCTAssertEqual(playback.fallbackNotice, "Sportsnet Event has nothing on · Playing Sportsnet One")
        XCTAssertEqual(server.resolveBodies().first?["eventId"] as? String, "espn:nhl:401")
        _ = await playback.stop()
        server.http.stop()
    }

    // MARK: The player's list: the game's own channels

    func testTheGamesChannelsHeadTheListForAPlayFromSport() {
        let channels = [channel("a", "Best"), channel("b", "Second"), channel("c", "Third")]
        let play = SportPlay(eventID: "e")
        XCTAssertEqual(PlayerGames.gameChannels(sportPlay: play, zapList: channels), channels, "best first, as C-I sends them")
        XCTAssertEqual(PlayerGames.gameChannels(sportPlay: nil, zapList: channels), [], "not a play from Sport")
        XCTAssertEqual(PlayerGames.gameChannels(sportPlay: play, zapList: [channels[0]]), [], "nothing else to watch it on")
        XCTAssertTrue(PlayerGames.hasOthers([], playing: nil, gameChannels: channels), "another channel is somewhere to go")
        XCTAssertFalse(PlayerGames.hasOthers([], playing: nil, gameChannels: []))
        XCTAssertEqual(PlayerGames.openingRow(gameChannels: channels, playingChannel: "1:b", playingGame: 0), 1,
                       "opens on the channel playing")
        XCTAssertEqual(PlayerGames.openingRow(gameChannels: [], playingChannel: "1:b", playingGame: 2), 2)
        XCTAssertEqual(PlayerGames.openingRow(gameChannels: channels, playingChannel: "1:z", playingGame: 1), 4,
                       "else the game playing, after the channel rows")
    }
}
