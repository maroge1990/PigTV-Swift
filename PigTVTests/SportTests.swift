import XCTest
@testable import PigTV

// C-I (build 30): sport events. The pure bucketing, league and text helpers
// (`SportRows`), tolerant decoding, and SportModel against FakePigTVServer.
final class SportRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, league: String = "NFL", from start: TimeInterval, minutes: Double,
                       channels: Int = 1) -> SportEvent {
        let begin = (now.timeIntervalSince1970 + start) * 1000
        return SportEvent(id: id, title: "Event \(id)", league: league, startTime: begin, endTime: begin + minutes * 60_000,
                          channels: (0..<channels).map { SportEventChannel(sourceId: 1, rawID: "\(id)-\($0)", name: "Channel \($0)") })
    }

    func testBucketsByTime() {
        let events = [
            event("upcoming-late", from: 3 * 3600, minutes: 60),
            event("live-late", from: -600, minutes: 60),
            event("soon", from: 25 * 60, minutes: 60),
            event("live-early", from: -3600, minutes: 120),
            event("ended", from: -7200, minutes: 60),
            event("edge-hour", from: 3600, minutes: 60),
            event("starts-now", from: 0, minutes: 60),
        ]
        let buckets = SportRows.buckets(events, now: now)
        XCTAssertEqual(buckets.live.map(\.id), ["live-early", "live-late", "starts-now"], "on now, by start")
        XCTAssertEqual(buckets.soon.map(\.id), ["soon", "edge-hour"], "within the next 60 min (inclusive)")
        XCTAssertEqual(buckets.later.map(\.id), ["upcoming-late"])
        XCTAssertFalse(buckets.all.contains { $0.id == "ended" }, "ended events are dropped")
        XCTAssertEqual(SportRows.nowAndNext(buckets).map(\.id), ["live-early", "live-late", "starts-now", "soon", "edge-hour"])
        XCTAssertEqual(SportRows.nowAndNext(buckets, limit: 2).count, 2)
    }

    func testLeaguesByCountAndFiltering() {
        let events = [event("a", league: "AFL", from: -60, minutes: 60), event("b", league: "NFL", from: -60, minutes: 60),
                      event("c", league: "NFL", from: 600, minutes: 60), event("d", league: "F1", from: 9000, minutes: 60),
                      event("e", league: "NRL", from: 9500, minutes: 60), event("f", league: "NFL", from: 9900, minutes: 60)]
        XCTAssertEqual(SportRows.leagues(events), ["NFL", "AFL", "F1", "NRL"], "most events first, ties in order")
        let buckets = SportRows.buckets(events, now: now)
        let nfl = SportRows.filter(buckets, league: "NFL")
        XCTAssertEqual(nfl.live.map(\.id), ["b"])
        XCTAssertEqual(nfl.soon.map(\.id), ["c"])
        XCTAssertEqual(nfl.later.map(\.id), ["f"])
        XCTAssertEqual(SportRows.filter(buckets, league: nil), buckets)
        XCTAssertTrue(SportRows.filter(buckets, league: "MLB").isEmpty)
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
        let clock = soon.start.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(SportRows.timing(soon, now: now), "\(clock) · in 12 min")
        XCTAssertEqual(SportRows.progress(live, now: now), 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(SportRows.progress(soon, now: now), 0)
        XCTAssertEqual(SportRows.progress(live, now: now.addingTimeInterval(7200)), 1)
        XCTAssertNil(SportRows.moreChannels(live))
        XCTAssertEqual(SportRows.moreChannels(event("two", from: 0, minutes: 1, channels: 2)), "+1 more channel")
        XCTAssertEqual(SportRows.moreChannels(event("three", from: 0, minutes: 1, channels: 3)), "+2 more channels")
    }

    func testLaterTitle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 1_800_000_000 is 08:00 UTC.
        XCTAssertEqual(SportRows.laterTitle([event("a", from: 3 * 3600, minutes: 60)], now: now, calendar: calendar), "Later today")
        XCTAssertEqual(SportRows.laterTitle([event("b", from: 17 * 3600, minutes: 60)], now: now, calendar: calendar), "Later")
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
    func testLoadsAndBucketsARealisticResponse() async throws {
        let server = try FakePigTVServer()
        let browse = BrowseModel(client: try server.client())
        XCTAssertFalse(browse.sportEnabled, "the harness server does not advertise sportsEvents")
        let sport = browse.sport
        await sport.load()
        XCTAssertTrue(sport.loaded)
        XCTAssertNil(sport.error)
        XCTAssertEqual(sport.live.map(\.id), ["nfl-1", "afl-1"])
        XCTAssertEqual(sport.soon.map(\.id), ["nrl-1"])
        XCTAssertEqual(sport.later.map(\.id), ["f1-1"])
        XCTAssertEqual(sport.leagues, ["NFL", "AFL", "NRL", "Sport"])
        let request = try XCTUnwrap(server.http.requests(path: "/api/sports/events", method: "GET").first)
        XCTAssertEqual(request.query, "hours=12")
        // The best channel becomes a player Channel with the event's fields.
        let best = browse.playable(try XCTUnwrap(sport.live.first?.best))
        XCTAssertEqual(best.id, "1:701")
        XCTAssertEqual(best.logo, "/api/logo/701")
        XCTAssertNil(best.number, "numbers only with channelNumbers")
        // Record: the event is the only programme on its best channel.
        let event = try XCTUnwrap(sport.soon.first)
        let row = browse.recordingRow(event, on: try XCTUnwrap(event.best))
        XCTAssertEqual(row.programmes, [event.programme])
        XCTAssertEqual(row.programmes.first?.startTime, event.startTime)
        server.http.stop()
    }

    func testAnOlderServerWithoutTheRouteHasNoEvents() async throws {
        let server = try FakePigTVServer(sportEvents: "")
        // An empty body does not decode: an error, but no events and no crash.
        let sport = SportModel(client: try server.client())
        await sport.load()
        XCTAssertTrue(sport.loaded)
        XCTAssertTrue(sport.buckets.isEmpty)
        server.http.stop()
    }

    func testWatchWhenStartsPlaysAtOnceWithinFiveMinutesElseWaits() async throws {
        let server = try FakePigTVServer()
        let client = try server.client()
        let browse = BrowseModel(client: client)
        let app = AppModel()
        app.configureClientForTesting(client, browse: browse)
        let saved = UserDefaults.standard.data(forKey: LastWatched.key)
        defer { UserDefaults.standard.set(saved, forKey: LastWatched.key) }
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
