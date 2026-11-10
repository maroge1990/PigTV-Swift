import XCTest
@testable import PigTV

// C-I: sport events. The pure text and channel rules (`SportRows`), tolerant decoding, SportModel against
// FakePigTVServer, and the SportsGame labels the front page draws.
final class SportRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, league: String = "NFL", from start: TimeInterval, minutes: Double,
                       channels: Int = 1, kind: SportEventKind = .event) -> SportEvent {
        let begin = (now.timeIntervalSince1970 + start) * 1000
        return SportEvent(id: id, title: "Event \(id)", league: league, startTime: begin, endTime: begin + minutes * 60_000,
                          channels: (0..<channels).map { SportEventChannel(sourceId: 1, rawID: "\(id)-\($0)", name: "Channel \($0)") },
                          kind: kind)
    }

    func testKindDecodesTolerantly() throws {
        func decode(_ kind: String) throws -> SportEventKind? {
            let json = #"{"events":[{"id":1,"title":"T","league":"NFL","start":1,"end":2,\#(kind)"channels":[{"sourceId":1,"id":"a","name":"A"}]}]}"#
            return try JSONDecoder().decode(SportEventsResponse.self, from: Data(json.utf8)).events.first?.kind
        }
        XCTAssertEqual(try decode(""), .event, "no kind: an event")
        XCTAssertEqual(try decode(#""kind":"replay","#), .replay)
        XCTAssertEqual(try decode(#""kind":"REPLAY","#), .replay)
        XCTAssertEqual(try decode(#""kind":"event","#), .event)
        XCTAssertEqual(try decode(#""kind":"highlights","#), .event, "unknown kinds read as events")
        XCTAssertEqual(try decode(#""kind":7,"#), .event, "a non-string kind does not drop the event")
    }

    func testTextAndProgress() {
        let live = event("live", from: -20 * 60, minutes: 60)
        let soon = event("soon", from: 12 * 60 - 30, minutes: 60)
        let later = event("later", from: 2 * 3600 + 5 * 60, minutes: 60)
        XCTAssertEqual(SportRows.endsIn(live, now: now), "ends in 40 min")
        XCTAssertEqual(SportRows.startsIn(soon, now: now), "starts in 12 min", "rounded up")
        XCTAssertEqual(SportRows.startsIn(later, now: now), "starts in 2 h 5 min")
        XCTAssertEqual(SportRows.startsIn(live, now: now), "starting now")
        XCTAssertEqual(SportRows.timing(live, now: now), "Live · ends in 40 min")
        XCTAssertTrue(SportRows.timing(event("replay", from: -600, minutes: 60, kind: .replay), now: now).hasPrefix("On now · "))
        let clock = soon.start.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(SportRows.timing(soon, now: now), "\(clock) · in 12 min")
        XCTAssertEqual(SportRows.progress(live, now: now), 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(SportRows.progress(soon, now: now), 0)
        XCTAssertEqual(SportRows.progress(live, now: now.addingTimeInterval(7200)), 1)
    }


    // Build 33 (Mark, live testing): choosing a secondary channel on an
    // upcoming event must offer Record/Watch when it starts, not tune at
    // once. `playsChannelNow` is the one rule the event page, its channel
    // list and the long-press picker all share.
    func testPlaysChannelNowMatchesLiveAndTheWatchNowWindow() {
        XCTAssertTrue(SportRows.playsChannelNow(event("live", from: -600, minutes: 60), now: now), "already on")
        XCTAssertTrue(SportRows.playsChannelNow(event("edge", from: SportRows.watchNowWindow, minutes: 60), now: now),
                      "exactly at the watch-now window: plays")
        XCTAssertFalse(SportRows.playsChannelNow(event("just-after", from: SportRows.watchNowWindow + 1, minutes: 60), now: now),
                       "one second past the window: offer a choice")
        XCTAssertFalse(SportRows.playsChannelNow(event("tomorrow", from: 26 * 3600, minutes: 60), now: now))
    }

    func testDecodesTolerantly() throws {
        let response = try JSONDecoder().decode(SportEventsResponse.self,
            from: Data(FakePigTVServer.sportEventsJSON(now: now).utf8))
        XCTAssertEqual(response.now, now.timeIntervalSince1970 * 1000)
        XCTAssertEqual(response.events.map(\.id), ["nfl-1", "afl-1", "nrl-1", "f1-1"],
                       "an event without channels and one that does not decode are dropped")
        let nfl = response.events[0]
        XCTAssertEqual(nfl.channels.map(\.rawID), ["701", "702", "88"], "a channel without a name is dropped")
        XCTAssertEqual(nfl.channels.map(\.quality), [.uhd, .hd, nil], "an unknown quality is nil")
        XCTAssertEqual(nfl.best?.logo, "/api/logo/701")
        XCTAssertEqual(nfl.best?.identityKey, "1:s:espn-uhd")
        XCTAssertEqual(nfl.channels[2].identityKey, "2:88")
        XCTAssertEqual(response.events[1].channels.first?.rawID, "504", "a numeric id reads as text")
        XCTAssertEqual(response.events[3].league, "Sport", "no league reads as Sport")
        XCTAssertEqual(response.events[3].channels.first?.quality, .hd, "quality is case-insensitive")
        XCTAssertEqual(nfl.end.timeIntervalSince(nfl.start), 180 * 60, "times are milliseconds")
    }

    @MainActor
    func testSportsEventsFlagDecodes() throws {
        let with = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"3","apiVersion":1,"features":{"library":true,"playbackResolve":true,"sportsEvents":true}}"#.utf8))
        XCTAssertEqual(with.features.sportsEvents, true)
        let without = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"name":"PigTV","version":"3","apiVersion":1,"features":{"library":true,"playbackResolve":true,"sportCategories":true}}"#.utf8))
        XCTAssertNil(without.features.sportsEvents, "an older server: no Sport tab or row")
    }
}

@MainActor
final class SportModelTests: XCTestCase {
    func testLoadsARealisticResponse() async throws {
        let server = try FakePigTVServer()
        let browse = BrowseModel(client: try server.client())
        XCTAssertFalse(browse.sportEnabled, "the harness server does not advertise sportsEvents")
        let sport = browse.sport
        await sport.load()
        XCTAssertTrue(sport.loaded)
        XCTAssertNil(sport.error)
        XCTAssertEqual(sport.events.map(\.id), ["nfl-1", "afl-1", "nrl-1", "f1-1"])
        XCTAssertEqual(sport.live.map(\.id), ["nfl-1", "afl-1"])
        XCTAssertEqual(sport.soon.map(\.id), ["nrl-1"], "f1-1 starts in 3 h 20 min: neither live nor soon")
        let request = try XCTUnwrap(server.http.requests(path: "/api/sports/events", method: "GET").first)
        XCTAssertEqual(request.query, "hours=72", "build 32: a whole weekend")
        // The best channel becomes a player Channel with the event's fields.
        let best = browse.playable(try XCTUnwrap(sport.live.first?.best))
        XCTAssertEqual(best.id, "1:701")
        XCTAssertEqual(best.logo, "/api/logo/701")
        XCTAssertEqual(best.number, 701, "the event channel's number")
        // Record: the event is the only programme on its best channel.
        let event = try XCTUnwrap(sport.soon.first)
        let row = browse.recordingRow(event, on: try XCTUnwrap(event.best))
        XCTAssertEqual(row.programmes, [event.programme])
        XCTAssertEqual(row.programmes.first?.startTime, event.startTime)
        server.http.stop()
    }

    /// `live` and `soon`: on now, and starting within the hour (inclusive), each by start; replays and ended events
    /// are in neither.
    func testLiveAndSoonLeaveOutReplaysAndEndedEvents() throws {
        let server = try FakePigTVServer()
        let sport = SportModel(client: try server.client())
        let now = Date().timeIntervalSince1970
        func event(_ id: String, from start: TimeInterval, minutes: Double, kind: SportEventKind = .event) -> SportEvent {
            SportEvent(id: id, title: id, league: "NFL", startTime: (now + start) * 1000, endTime: (now + start + minutes * 60) * 1000,
                       channels: [SportEventChannel(sourceId: 1, rawID: id, name: id)], kind: kind)
        }
        sport.setFixture([
            event("upcoming-late", from: 3 * 3600, minutes: 60),
            event("live-late", from: -600, minutes: 60),
            event("soon", from: 25 * 60, minutes: 60),
            event("live-early", from: -3600, minutes: 120),
            event("ended", from: -7200, minutes: 60),
            event("edge-hour", from: 3600 - 30, minutes: 60),
            event("replay-now", from: -1800, minutes: 120, kind: .replay),
            event("replay-soon", from: 20 * 60, minutes: 120, kind: .replay),
        ])
        XCTAssertEqual(sport.live.map(\.id), ["live-early", "live-late"])
        XCTAssertEqual(sport.soon.map(\.id), ["soon", "edge-hour"])
        server.http.stop()
    }

    func testAnOlderServerWithoutTheRouteHasNoEvents() async throws {
        let server = try FakePigTVServer(sportEvents: "")
        // An empty body does not decode: an error, but no events and no crash.
        let sport = SportModel(client: try server.client())
        await sport.load()
        XCTAssertTrue(sport.loaded)
        XCTAssertTrue(sport.events.isEmpty)
        server.http.stop()
    }

    /// #20 (server 0337): an event airs on two channels at different times (its own span merges them). Watch when it
    /// starts, Record and the Watch-now rule on the later channel use that channel's airing, not the event's start.
    /// Written against JSON and the old entry points so it runs (and fails) on build 73 too.
    func testTheChosenChannelsOwnAiringDrivesWatchWhenStartsAndRecord() async throws {
        let server = try FakePigTVServer()
        let client = try server.client()
        let browse = BrowseModel(client: client)
        let app = AppModel()
        app.configureClientForTesting(client, browse: browse)
        let now = Date()
        let ms = { (seconds: Double) in Int64((now.timeIntervalSince1970 + seconds) * 1000) }
        let json = """
        {"id":"q","title":"Mexico City GP · Qualifying","league":"F1","start":\(ms(240)),"end":\(ms(3600 + 5400)),
         "channels":[{"sourceId":1,"id":"live1","name":"Live One","start":\(ms(240)),"end":\(ms(3840))},
                     {"sourceId":1,"id":"late2","name":"Delayed Two","start":\(ms(3600)),"end":\(ms(3600 + 5400))}]}
        """
        let event = try JSONDecoder().decode(SportEvent.self, from: Data(json.utf8))
        let late = event.channels[1]
        app.watchWhenStarts(event, channel: late, now: now)
        XCTAssertNil(app.playback, "the delayed channel starts in an hour: nothing plays yet")
        XCTAssertEqual(app.pendingWatch?.channelName, "Delayed Two")
        XCTAssertEqual(try XCTUnwrap(app.pendingWatch?.at).timeIntervalSince1970, now.timeIntervalSince1970 + 3600, accuracy: 0.01,
                       "it waits for that channel's own start")
        app.cancelPendingWatch()
        let row = browse.recordingRow(event, on: late)
        XCTAssertEqual(row.programmes.first?.startTime, Double(ms(3600)), "Record covers the delayed airing")
        XCTAssertEqual(row.programmes.first?.endTime, Double(ms(3600 + 5400)))
        XCTAssertFalse(SportRows.playsChannelNow(event, on: late, now: now), "the late channel offers a choice")
        XCTAssertTrue(SportRows.playsChannelNow(event, on: event.channels[0], now: now), "the live channel plays now")
        // An older server's channel has no times: the event's own.
        let old = SportEventChannel(sourceId: 1, rawID: "old", name: "Old")
        XCTAssertEqual(event.airing(on: old).start, event.startTime)
        server.http.stop()
    }

    func testWatchWhenStartsPlaysAtOnceWithinFiveMinutesElseWaits() async throws {
        let server = try FakePigTVServer()
        let client = try server.client()
        let browse = BrowseModel(client: client)
        let app = AppModel()
        app.configureClientForTesting(client, browse: browse)
        let now = Date()
        let channel = SportEventChannel(sourceId: 1, rawID: "w1", name: "Watch One")
        let far = SportEvent(id: "far", title: "Far", league: "NFL", startTime: (now.timeIntervalSince1970 + 3600) * 1000,
                             endTime: (now.timeIntervalSince1970 + 7200) * 1000, channels: [channel])
        app.watchWhenStarts(far, now: now)
        XCTAssertEqual(app.pendingWatch?.eventID, "far")
        XCTAssertNil(app.playback, "nothing plays before the start")
        app.cancelPendingWatch()
        XCTAssertNil(app.pendingWatch)
        let near = SportEvent(id: "near", title: "Near", league: "NFL", startTime: (now.timeIntervalSince1970 + 240) * 1000,
                              endTime: (now.timeIntervalSince1970 + 3600) * 1000, channels: [channel])
        app.watchWhenStarts(near, now: now)
        XCTAssertNil(app.pendingWatch)
        XCTAssertEqual(app.playback?.channel.id, "1:w1", "within five minutes it plays now")
        if let playback = app.playback { await app.endPlayback(playback) }
        server.http.stop()
    }
}

// Build 31: a tab's appearance reloads only what is older than a minute;
// Refresh/Retry (the plain loads) always go to the server.
@MainActor
final class AppearLoadTests: XCTestCase {
    func testAppearLoadsSkipFreshDataButExplicitLoadsDoNot() async throws {
        let server = try FakePigTVServer()
        let browse = BrowseModel(client: try server.client())
        await browse.loadFavouritesIfStale()
        await browse.loadFavouritesIfStale()
        await browse.loadRecordingsIfStale()
        await browse.loadRecordingsIfStale()
        XCTAssertEqual(server.http.requests(path: "/api/library/favourites").count, 1)
        XCTAssertEqual(server.http.requests(path: "/api/recordings").count, 1)
        await browse.loadRecordings()
        XCTAssertEqual(server.http.requests(path: "/api/recordings").count, 2, "Refresh always reloads")
        await browse.loadFavouritesIfStale(maxAge: 0)
        XCTAssertEqual(server.http.requests(path: "/api/library/favourites").count, 2, "stale data reloads")
        server.http.stop()
    }
}

@MainActor
final class SportPresenterTests: XCTestCase {
    func testPresenterRunsTheActionOnlyAfterThePageHasClosed() throws {
        let server = try FakePigTVServer()
        let sport = SportModel(client: try server.client())
        sport.setFixture(GuideFixtures.largeSportEvents(from: GuideFixtures.channels(), count: 10))
        let presenter = SportPresenter(app: AppModel())
        let event = try XCTUnwrap(sport.events.first)
        presenter.open(event, .details)
        XCTAssertEqual(presenter.presented?.event.id, event.id)
        var ran = false
        presenter.close(then: { ran = true })
        XCTAssertNil(presenter.presented)
        XCTAssertFalse(ran, "not until the cover's onDismiss")
        presenter.dismissed()
        XCTAssertTrue(ran)
        presenter.dismissed()
    }
}

/// The SportsGame labels the front page draws (C-O's game shape), and the recording badge's channel identity.
final class SportsGameTests: XCTestCase {
  nonisolated static func payload(league: String = "NFL", freshness: String = "fresh") -> String {
    let (status, start, end, watch) = ("live", 1000, 9000, true)
    return #"{"games":[{"id":"game","league":"\#(league)","title":"Chiefs v Bills","start":\#(start),"end":null,"session":null,"circuit":null,"format":null,"competitors":[{"id":"a","name":"Chiefs","logo":"/api/logo/a"},{"id":"b","name":"Bills","logo":null}],"status":"\#(status)","freshness":"\#(freshness)","progress":{"period":5,"clock":"1:23","half":"top","day":"Day 2","overs":"90"},"scores":["17","14"],"situation":{"down":3,"distance":10,"balls":2,"strikes":1,"outs":1,"onFirst":true},"availability":"matched","broadcastStatus":"on-tv","channels":[{"sourceId":1,"id":"pos_7","stableId":"stable7","name":"Sports HD"}],"events":[{"id":"airing","start":\#(start),"end":\#(end)}],"canWatch":\#(watch)}]}"#
  }
  private struct Games: Decodable { let games: [SportsGame] }
  private func firstGame(_ json: String) throws -> SportsGame? {
    try JSONDecoder().decode(Games.self, from: Data(json.utf8)).games.first
  }
  @MainActor func testRecordingBadgeUsesSourceAndStableIdentityInsteadOfChannelName() throws {
    let store = RecordingsStore()
    let marks = ScheduleMarks(following: store)
    let row = #"[{"id":1,"title":"Game","channel_name":"Sports HD","program_start":1000,"program_end":9000,"status":"recording","source_id":1,"channel_item_id":"pos_7","channel_stable_id":"stable7"}]"#
    store.schedules = try JSONDecoder().decode([ScheduledRecording].self, from: Data(row.utf8))
    XCTAssertFalse(marks.isRecording(SportEventChannel(sourceId: 2, rawID: "pos_7", stableId: "stable7", name: "Sports HD")))
    XCTAssertFalse(marks.isRecording(SportEventChannel(sourceId: 1, rawID: "pos_7", stableId: "other", name: "Sports HD")))
    XCTAssertTrue(marks.isRecording(SportEventChannel(sourceId: 1, rawID: "pos_99", stableId: "stable7", name: "Renamed Sports")))
    store.schedules = []
    XCTAssertFalse(marks.isRecording(SportEventChannel(sourceId: 1, rawID: "pos_99", stableId: "stable7", name: "Renamed Sports")))
  }
  @MainActor func testRecordingBadgeNeverGuessesAnIdentityForOldSchedules() throws {
    let store = RecordingsStore()
    let marks = ScheduleMarks(following: store)
    let row = #"[{"id":1,"title":"Game","channel_name":"Sports HD","program_start":1000,"program_end":9000,"status":"recording"}]"#
    store.schedules = try JSONDecoder().decode([ScheduledRecording].self, from: Data(row.utf8))
    XCTAssertFalse(marks.isRecording(SportEventChannel(sourceId: 1, rawID: "pos_7", stableId: "stable7", name: "Sports HD")))
    XCTAssertTrue(marks.recordingChannels.contains("Sports HD"), "Ordinary Guide's existing marks remain separate")
  }
  func testSevenFamiliesAndNeutralProgressWithoutFabricatedSituations() throws {
    let leagues: [String: SportsGame.Family] = [
      "AFL": .australianFootball, "NBA": .basketball, "EPL": .football, "FA Cup": .football,
      "UEFA": .football, "Championship": .football, "NFL": .americanFootball, "MLB": .baseball,
      "Cricket": .cricket, "F1": .motorsport,
    ]
    for (league, family) in leagues {
      let game = try XCTUnwrap(firstGame(Self.payload(league: league)))
      XCTAssertEqual(game.family, family)
      XCTAssertEqual(game.statusLabel, "LIVE")
      XCTAssertNil(game.visibleScores(hidden: true))
      XCTAssertNil(game.situationLabel(hidden: true))
      if league == "F1" {
        XCTAssertNil(game.visibleScores(hidden: false))
        XCTAssertEqual(game.progressLabel(), "")
      }
      if league == "MLB" {
        XCTAssertTrue(game.progressLabel().contains("Top 5"))
        XCTAssertTrue(game.situationLabel(hidden: false)?.contains("First") == true)
      }
      if league == "NBA" || league == "NFL" {
        XCTAssertTrue(game.progressLabel().contains("Overtime 1"))
      }
      if league == "EPL" { XCTAssertTrue(game.progressLabel().contains("Penalties")) }
      if league == "Cricket" { XCTAssertTrue(game.progressLabel().contains("Day 2")) }
    }
    let stale = try XCTUnwrap(firstGame(Self.payload(freshness: "stale")))
    XCTAssertNil(stale.visibleScores(hidden: false))
    XCTAssertNil(stale.situationLabel(hidden: false))
    XCTAssertEqual(stale.progressLabel(), "")
    XCTAssertEqual(stale.statusLabel, "ON TV NOW")
  }
}
