import XCTest
@testable import PigTV

// C-I (build 30): sport events. The pure bucketing, league and text helpers
// (`SportRows`), tolerant decoding, and SportModel against FakePigTVServer.
final class SportRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, league: String = "NFL", from start: TimeInterval, minutes: Double,
                       channels: Int = 1, kind: SportEventKind = .event) -> SportEvent {
        let begin = (now.timeIntervalSince1970 + start) * 1000
        return SportEvent(id: id, title: "Event \(id)", league: league, startTime: begin, endTime: begin + minutes * 60_000,
                          channels: (0..<channels).map { SportEventChannel(sourceId: 1, rawID: "\(id)-\($0)", name: "Channel \($0)") },
                          kind: kind)
    }

    // Build 31: replays have their own section, on now first then by start;
    // never in On now / Starting soon / Later or Home; the chips count them.
    func testReplaysAreTheirOwnBucket() {
        let events = [
            event("live", from: -600, minutes: 60),
            event("replay-later", league: "AFL", from: 2 * 3600, minutes: 120, kind: .replay),
            event("replay-soon", from: 20 * 60, minutes: 120, kind: .replay),
            event("replay-now", from: -1800, minutes: 120, kind: .replay),
            event("replay-ended", from: -4 * 3600, minutes: 60, kind: .replay),
            event("soon", from: 30 * 60, minutes: 60),
        ]
        let buckets = SportRows.buckets(events, now: now)
        XCTAssertEqual(buckets.live.map(\.id), ["live"])
        XCTAssertEqual(buckets.soon.map(\.id), ["soon"])
        XCTAssertTrue(buckets.later.isEmpty)
        XCTAssertEqual(buckets.replays.map(\.id), ["replay-now", "replay-soon", "replay-later"])
        XCTAssertEqual(SportRows.nowAndNext(buckets).map(\.id), ["live", "soon"], "no replays on Home")
        XCTAssertEqual(buckets.all.count, 5)
        XCTAssertEqual(SportRows.leagues(buckets.all), ["NFL", "AFL"])
        XCTAssertEqual(SportRows.filter(buckets, league: "AFL").replays.map(\.id), ["replay-later"])
        XCTAssertTrue(SportRows.filter(buckets, league: "AFL").live.isEmpty)
        XCTAssertTrue(SportRows.timing(buckets.replays[0], now: now).hasPrefix("On now · "))
        XCTAssertFalse(SportRows.buckets([event("r", from: 600, minutes: 60, kind: .replay)], now: now).isEmpty)
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
        let counts = SportRows.leagueCounts(events)
        XCTAssertEqual(counts["NFL"], 3)
        XCTAssertEqual(counts["AFL"], 1)
        XCTAssertEqual(counts["F1"], 1)
        XCTAssertEqual(counts["NRL"], 1)
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

    // Build 32: a 72 h window in sections by the device's calendar day:
    // Later today, Tomorrow, then one per weekday; "Sat 1:30 pm" times.
    func testDaySectionsOverSeventyTwoHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_AU")
        // 1_800_000_000 is Friday 15 January 2027, 08:00 UTC.
        let events = [
            event("sun", league: "NFL", from: 50 * 3600, minutes: 180),          // Sunday 10:00
            event("today", league: "AFL", from: 5 * 3600, minutes: 120),         // Friday 13:00
            event("sat-late", league: "AFL", from: 38 * 3600, minutes: 120),     // Saturday 22:00
            event("tomorrow", league: "NRL", from: 20 * 3600, minutes: 120),     // Saturday 04:00
            event("sat", league: "NFL", from: 29 * 3600 + 1800, minutes: 180),   // Saturday 13:30
            event("mon", league: "F1", from: 64 * 3600, minutes: 60),            // Monday 00:00
            event("soon", from: 30 * 60, minutes: 60),
            event("replay-sun", league: "NFL", from: 51 * 3600, minutes: 60, kind: .replay),
        ]
        let buckets = SportRows.buckets(events, now: now, calendar: calendar)
        XCTAssertEqual(buckets.soon.map(\.id), ["soon"])
        XCTAssertEqual(buckets.later.map(\.id), ["today"], "later today")
        XCTAssertEqual(buckets.tomorrow.map(\.id), ["tomorrow", "sat", "sat-late"], "Saturday is tomorrow, by start")
        XCTAssertEqual(buckets.days.map(\.title), ["Sunday", "Monday"])
        XCTAssertEqual(buckets.days.map { $0.events.map(\.id) }, [["sun"], ["mon"]])
        XCTAssertEqual(buckets.replays.map(\.id), ["replay-sun"], "replays stay last, whatever the day")
        XCTAssertEqual(SportRows.nowAndNext(buckets).map(\.id), ["soon"], "Home: live and the next 60 min only")
        // The chips count the whole window.
        XCTAssertEqual(SportRows.leagues(buckets.all), ["NFL", "AFL", "NRL", "F1"])
        let nfl = SportRows.filter(buckets, league: "NFL")
        XCTAssertEqual(nfl.tomorrow.map(\.id), ["sat"])
        XCTAssertEqual(nfl.days.map(\.title), ["Sunday"], "a day without the league's events is dropped")
        // Times: today "1:00 pm · in 5 h"; other days "Sat 1:30 pm".
        let today = SportRows.timing(events[1], now: now, calendar: calendar)
        XCTAssertTrue(today.hasSuffix("· in 5 h"), today)
        let saturday = SportRows.timing(events[4], now: now, calendar: calendar)
        XCTAssertTrue(saturday.hasPrefix("Sat ") && saturday.contains("1:30") && !saturday.contains("·"), saturday)
        XCTAssertTrue(SportRows.timing(events[0], now: now, calendar: calendar).hasPrefix("Sun "))
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

    // Production-sized fixture: 215 events with 153 replays (71%), and remaining
    // 62 spread across live, soon, later, tomorrow and future days. All non-replay
    // buckets must be non-empty.
    func testLargeSportEventsFixtureFor215() {
        let guide = GuideFixtures.channels()
        let events = GuideFixtures.largeSportEvents(from: guide, count: 215, now: now)
        let buckets = SportRows.buckets(events, now: now)

        XCTAssertEqual(buckets.all.count, 215, "215 total events")
        XCTAssertEqual(buckets.replays.count, 153, "153 replays (71%)")
        let nonReplays = buckets.live.count + buckets.soon.count + buckets.later.count +
                        buckets.tomorrow.count + buckets.days.flatMap(\.events).count
        XCTAssertEqual(nonReplays, 62, "62 non-replay events")

        XCTAssertGreaterThan(buckets.live.count, 0, "live bucket must be non-empty")
        XCTAssertGreaterThan(buckets.soon.count, 0, "soon bucket must be non-empty")
        XCTAssertGreaterThan(buckets.later.count, 0, "later bucket must be non-empty")
        XCTAssertGreaterThan(buckets.tomorrow.count, 0, "tomorrow bucket must be non-empty")
        XCTAssertGreaterThan(buckets.days.count, 0, "days bucket must have entries")

        let leagues = SportRows.leagues(events)
        XCTAssertGreaterThanOrEqual(leagues.count, 8, "at least 8 distinct leagues")
    }

    // Test that largeSportEvents scales proportionally: 600 events with ~71% replays.
    func testLargeSportEventsScalesProportionally() {
        let guide = GuideFixtures.channels()
        let events = GuideFixtures.largeSportEvents(from: guide, count: 600, now: now)
        let buckets = SportRows.buckets(events, now: now)

        XCTAssertEqual(buckets.all.count, 600, "600 total events")
        let replayPercent = Double(buckets.replays.count) / Double(buckets.all.count)
        XCTAssertEqual(replayPercent, 0.71, accuracy: 0.01, "maintains ~71% replays")
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
        // f1-1 starts in 3 h 20 min: later today, or tomorrow late in the evening.
        XCTAssertEqual((sport.later + sport.tomorrow).map(\.id), ["f1-1"])
        XCTAssertEqual(sport.leagues, ["NFL", "AFL", "NRL", "Sport"])
        let request = try XCTUnwrap(server.http.requests(path: "/api/sports/events", method: "GET").first)
        XCTAssertEqual(request.query, "hours=72", "build 32: a whole weekend")
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
        await browse.loadRecentIfStale()
        await browse.loadRecentIfStale()
        XCTAssertEqual(server.http.requests(path: "/api/library/favourites").count, 1)
        XCTAssertEqual(server.http.requests(path: "/api/recordings").count, 1)
        XCTAssertEqual(server.http.requests(path: "/api/library/recent").count, 1)
        await browse.loadRecordings()
        XCTAssertEqual(server.http.requests(path: "/api/recordings").count, 2, "Refresh always reloads")
        await browse.loadFavouritesIfStale(maxAge: 0)
        XCTAssertEqual(server.http.requests(path: "/api/library/favourites").count, 2, "stale data reloads")
        server.http.stop()
    }
}
